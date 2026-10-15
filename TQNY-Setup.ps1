<#
===========================================================================
 TQNY-Setup.ps1   --   TQNY IT Setup v4.0  (Windows app)

 One window for everything a technician does on a PC, before and after a
 format: rename, network, Wi-Fi, sharing, printers, apps, Windows Update,
 drivers, firewall, activation, backup / restore, repair and cleanup.

 Run it:
   - double-click TQNY-Setup.bat  (next to this file), or
   - from any PC with internet:
       irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex

 Rules this tool keeps (same as v3.x):
   - Nothing changes until you confirm. Read-only checks just run.
   - Administrator is asked once at start. Decline and it opens read-only.
   - The rename never hands out a number it cannot record, and never
     touches a protected PC. The name registry (TQNY-Names.csv) is shared
     with the classic console tool, TQNY-Classic.bat.
   - Long jobs run in the background, so the window never freezes, and
     every job can be stopped from the log bar.

 Pure ASCII on purpose: Windows PowerShell 5.1 reads BOM-less files as ANSI.
===========================================================================
#>
# No [CmdletBinding()] on purpose: it adds -Debug, whose alias 'db' clashes with -Db.
param(
    # Name registry CSV. Default: TQNY-Names.csv next to this script.
    [string]$Db,
    # Name prefix for numbered names, e.g. ACME gives ACME-01.
    [string]$Prefix,
    # Site code written to the registry and the handover sheet.
    [string]$Site,
    # Set by the internet launcher. Renaming stays off until a registry is set.
    [switch]$Remote,
    # Do not offer to restart as Administrator.
    [switch]$NoElevate
)

# ---------------------------------------------------------------------------
#  CONFIG - edit these if needed
# ---------------------------------------------------------------------------

# Default prefix for numbered names: TQNY-01, TQNY-02, ...
$TQNY_PREFIX = 'TQNY'

# Machines that must NEVER be renamed by this tool.
# MACs: no separators, uppercase.  Names: current computer names.
$PROTECTED_MACS  = @('74563CC0AE41')
$PROTECTED_NAMES = @('ZW0V')

# How many one-second tries to wait for the registry lock.
$LOCK_TRIES = 20

# Time zone offered by default. Saudi Arabia is UTC+3.
$TZ_WANT = 'Arab Standard Time'

# ---------------------------------------------------------------------------
#  Do not edit below this line
# ---------------------------------------------------------------------------

$TOOL_VERSION = '4.0'

$Company = @{
    Name   = 'TQNY Company - Software Licenses & Hardware Solutions'
    Site   = 'tqnyprofile.com'
    Store  = 'tqny.store'
    CR     = 'CR 7049547834'
    Maroof = 'Maroof #358680'
    Mail   = 'info@tqny.store'
    Phone  = '+966 58 032 4564'
}

$ErrorActionPreference = 'Continue'
$StartClock = [System.Diagnostics.Stopwatch]::StartNew()
$StartMarks = New-Object System.Collections.ArrayList
$ScriptPath = $PSCommandPath
if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }
$ScriptDir = if ($ScriptPath) { Split-Path -Parent $ScriptPath } else { (Get-Location).Path }

function Get-RelaunchArgs {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$ScriptPath`"")
    if ($Db)     { $a += @('-Db', "`"$Db`"") }
    if ($Prefix) { $a += @('-Prefix', "`"$Prefix`"") }
    if ($Site)   { $a += @('-Site', "`"$Site`"") }
    if ($Remote) { $a += '-Remote' }
    return $a
}

# WPF needs a single-threaded apartment. Windows PowerShell 5.1 is STA by
# default, but a host started with -MTA (or PowerShell 7 on some setups) is not.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    if ($ScriptPath) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-RelaunchArgs) | Out-Null
    } else {
        Write-Host 'TQNY IT Setup must be started from its file with powershell.exe -STA.' -ForegroundColor Red
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# Ask for admin once, up front, so there is no mid-session UAC prompt.
if (-not $IsAdmin -and -not $NoElevate -and $ScriptPath) {
    $msg = "TQNY IT Setup needs Administrator rights to rename the PC, change network settings, " +
           "install apps and run repairs. Checking and reporting work without them.`n`n" +
           "Restart as Administrator now?`n`n(No = open in read-only mode)"
    $ans = [System.Windows.MessageBox]::Show($msg, "TQNY IT Setup v$TOOL_VERSION", 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ((Get-RelaunchArgs) + '-NoElevate') -ErrorAction Stop | Out-Null
            return
        } catch {
            [void][System.Windows.MessageBox]::Show('Elevation was cancelled. Opening in read-only mode.',
                "TQNY IT Setup v$TOOL_VERSION", 'OK', 'Information')
        }
    }
}

# The dark title bar needs a tiny compiled helper. Compiling takes a second
# or two, so it happens on a background thread while the window is built.
$DwmJob = $null
try {
    $DwmJob = [powershell]::Create()
    [void]$DwmJob.AddScript({
        if (-not ('TQNY.Dwm' -as [type])) {
            Add-Type -Namespace TQNY -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);'
        }
    })
    $DwmHandle = $DwmJob.BeginInvoke()
} catch { $DwmJob = $null }

# ---------------------------------------------------------------------------
#  Shared state. $Cfg and $sync are handed to the background runspace, so
#  both threads see the same objects.
# ---------------------------------------------------------------------------
$Cfg = [hashtable]::Synchronized(@{})
$Cfg.Version        = $TOOL_VERSION
$Cfg.Company        = $Company
$Cfg.ScriptDir      = $ScriptDir
$Cfg.ScriptPath     = $ScriptPath
$Cfg.Remote         = [bool]$Remote
$Cfg.IsAdmin        = [bool]$IsAdmin
$Cfg.LockTries      = $LOCK_TRIES
$Cfg.ProtectedMacs  = $PROTECTED_MACS
$Cfg.ProtectedNames = $PROTECTED_NAMES
$Cfg.DefaultPrefix  = $TQNY_PREFIX
$Cfg.TZ             = $TZ_WANT
$Cfg.Tech           = $env:USERNAME
$Cfg.Site           = '-'
$Cfg.Prefix         = $TQNY_PREFIX
$Cfg.DbExplicit     = [bool]$Db
$Cfg.DbFile         = Join-Path $ScriptDir 'TQNY-Names.csv'
if ($Db) { $Cfg.DbFile = $Db.Trim().Trim('"') }

# Logs, settings and handover sheets live next to the tool, unless it was
# launched from a temp folder (the internet launcher), where they would be
# deleted on exit.
$tempRoots = @($env:TEMP, [IO.Path]::GetTempPath()) | Where-Object { $_ }
$inTemp = $false
foreach ($t in $tempRoots) { if ($ScriptDir -like ($t.TrimEnd('\') + '*')) { $inTemp = $true } }
if ($ScriptDir -like '*\AppData\Local\Temp*') { $inTemp = $true }
$Cfg.DataDir = if ($Remote -or $inTemp) { Join-Path $env:ProgramData 'TQNY-Setup' } else { $ScriptDir }
$Cfg.SettingsFile = Join-Path $Cfg.DataDir 'tqny-settings.json'

# Saved settings (technician, site, prefix, registry path) from last time.
if (Test-Path -LiteralPath $Cfg.SettingsFile) {
    try {
        $saved = Get-Content -LiteralPath $Cfg.SettingsFile -Raw | ConvertFrom-Json
        if ($saved.Tech)   { $Cfg.Tech = [string]$saved.Tech }
        if ($saved.Site)   { $Cfg.Site = [string]$saved.Site }
        if ($saved.Prefix) { $Cfg.Prefix = [string]$saved.Prefix }
        if ($saved.TZ)     { $Cfg.TZ = [string]$saved.TZ }
        if ($saved.DbFile -and -not $Db -and -not $Remote) { $Cfg.DbFile = [string]$saved.DbFile }
    } catch { }
}
if ($Prefix) { $Cfg.Prefix = $Prefix.Trim().Trim('"') }
if ($Site)   { $Cfg.Site = $Site.Trim().Trim('"') }

$sync = [hashtable]::Synchronized(@{})
$sync.Queue        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$sync.Done         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.Apps         = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.Cancel       = $false
$sync.Progress     = -1
$sync.Status       = ''
$sync.RebootNeeded = $false
$sync.LastNet      = $null
$sync.LockHeld     = $null
$sync.FailCount    = 0
$sync.NewName      = $null

# ===========================================================================
#  WORKER LIBRARY
#  Everything inside $WorkerLib runs in the background runspace (and is also
#  dot-sourced into the window's runspace for quick read-only calls). It may
#  only talk to the window through $sync and read settings from $Cfg / $Facts.
# ===========================================================================
$WorkerLib = {

# ---- logging --------------------------------------------------------------
function Log { param([string]$Text = '', [string]$Kind = 'text') $sync.Queue.Enqueue([object[]]@($Kind, $Text)) }
function Head { param([string]$Text) Log ''; Log "=== $Text ===" 'head' }
function Ok   { param([string]$Text) Log "  [OK]    $Text" 'ok' }
function Warn { param([string]$Text) Log "  [WARN]  $Text" 'warn' }
function Fail { param([string]$Text) $sync.FailCount = [int]$sync.FailCount + 1; Log "  [FAIL]  $Text" 'fail' }
function Info { param([string]$Text) Log "  $Text" 'text' }
function Dim  { param([string]$Text) Log "  $Text" 'dim' }
# Done = something was changed on this PC. It goes on the handover sheet.
function Done { param([string]$Text) [void]$sync.Done.Add($Text); Log "  [OK]    $Text" 'ok' }
function Set-Progress { param([double]$Value = -1, [string]$Status = '') $sync.Progress = $Value; if ($Status) { $sync.Status = $Status } }
function Test-Cancel { if ($sync.Cancel) { throw 'TQNY_CANCELLED' } }

# Format objects as an aligned text table in the log.
function Out-Table {
    param([Parameter(ValueFromPipeline = $true)]$InputObject, [object[]]$Property)
    begin { $all = New-Object System.Collections.ArrayList }
    process { if ($null -ne $InputObject) { [void]$all.Add($InputObject) } }
    end {
        if ($all.Count -eq 0) { Dim '(none)'; return }
        if ($Property) { $txt = $all | Format-Table -AutoSize -Property $Property | Out-String -Width 260 }
        else { $txt = $all | Format-Table -AutoSize | Out-String -Width 260 }
        foreach ($l in ($txt -split "`r?`n")) { if ($l.Trim()) { Log ('  ' + $l.TrimEnd()) 'text' } }
    }
}

# Progress spinners and bars from winget / DISM that would flood the log.
function Test-NoiseLine {
    param([string]$s)
    $t = $s.Trim()
    if ($t.Length -le 1) { return $true }
    if ($t -match '^[\-\\\|/]+$') { return $true }
    if ($t.IndexOf([char]0x2588) -ge 0 -or $t.IndexOf([char]0x2592) -ge 0) { return $true }
    if ($t -match '^\d+(\.\d+)?\s*(B|KB|MB|GB)\s*/\s*\d') { return $true }
    return $false
}

# Run a console program, streaming its output into the log. Returns the exit code.
function Invoke-Native {
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$ArgList = @(), [switch]$Quiet, [string]$Indent = '    ')
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        & $File @ArgList 2>&1 | ForEach-Object {
            $s = [string]$_
            # sfc and a few others write UTF-16, which arrives with NULs between letters.
            if ($s.IndexOf([char]0) -ge 0) { $s = $s.Replace([string][char]0, '') }
            if ($s.Contains("`r")) {
                $parts = @($s -split "`r" | Where-Object { $_.Trim() })
                $s = if ($parts.Count) { $parts[-1] } else { '' }
            }
            if (-not $Quiet -and $s.Trim() -and -not (Test-NoiseLine $s)) { Log ($Indent + $s.TrimEnd()) 'dim' }
            if ($sync.Cancel) { throw 'TQNY_CANCELLED' }
        }
    } catch {
        if ("$_" -eq 'TQNY_CANCELLED') { throw }
        Fail "$File : $($_.Exception.Message)"
        return -1
    }
    return [int]$LASTEXITCODE
}

# Run a console program and return its output as text, without logging it.
function Get-NativeText {
    param([Parameter(Mandatory = $true)][string]$File, [string[]]$ArgList = @())
    $ErrorActionPreference = 'Continue'
    try { return ((& $File @ArgList 2>&1 | ForEach-Object { [string]$_ }) -join "`n").Replace([string][char]0, '') } catch { return '' }
}

# ---- small helpers ----------------------------------------------------------
# Same cleaning as v3.x so fingerprints and registry rows stay identical.
function Clean { param($v) $s = [string]$v; if ($s.Trim()) { ($s -replace '[^A-Za-z0-9 ._:-]', '').Trim() } else { '-' } }
# Board makers often leave placeholder text where the serial should be.
function Get-RealSerial { param($v) $s = ([string]$v).Trim(); if (-not $s -or $s -match '^(Default string|To be filled.*|System Serial Number|None|N/A|O\.E\.M\.?|Not Specified|0+|\.+)$') { '-' } else { $s } }
function Get-Stamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }
function Get-UtcNow { (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') }
function Test-IPv4 { param([string]$s) $ip = $null; return ([System.Net.IPAddress]::TryParse($s, [ref]$ip) -and $ip.AddressFamily -eq 'InterNetwork' -and $s -match '^\d+\.\d+\.\d+\.\d+$') }

function Set-RegValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    if (-not (Test-Path -Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}
function Remove-RegValue { param([string]$Path, [string]$Name) Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }

function Test-Ping {
    param([string]$Target, [int]$Timeout = 1000, [int]$Count = 2)
    $p = New-Object System.Net.NetworkInformation.Ping
    for ($i = 0; $i -lt $Count; $i++) {
        try { if ($p.Send($Target, $Timeout).Status -eq 'Success') { return $true } } catch { }
    }
    return $false
}

function Get-WebText {
    param([string]$Url, [int]$TimeoutMs = 8000)
    try {
        $rq = [System.Net.HttpWebRequest]::Create($Url)
        $rq.Timeout = $TimeoutMs; $rq.ReadWriteTimeout = $TimeoutMs; $rq.UserAgent = 'TQNY-Setup'
        $rs = $rq.GetResponse()
        $sr = New-Object System.IO.StreamReader($rs.GetResponseStream())
        $t = $sr.ReadToEnd(); $sr.Close(); $rs.Close()
        return $t
    } catch { return $null }
}

function Get-WebFile {
    param([string]$Url, [string]$OutFile)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'TQNY-Setup')
        $wc.DownloadFile($Url, $OutFile)
        return $true
    } catch { Fail "Download failed: $Url - $($_.Exception.Message)"; return $false }
}

function Get-ActiveAdapter {
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
}

function New-TempDir {
    param([string]$Tag = 'tmp')
    # ProgramData has no spaces in its path, which keeps netsh and friends happy.
    $d = Join-Path $env:ProgramData ('TQNY-Setup\tmp\' + $Tag + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Test-NeedAdmin {
    if ($Cfg.IsAdmin) { return $true }
    Fail 'This needs Administrator. Close the tool and start it again, choosing Yes at the Administrator prompt.'
    return $false
}

function Get-WindowsEdition {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    return @{
        Caption = [string]$os.Caption
        Build   = [string]$os.BuildNumber
        UBR     = [string]$cv.UBR
        Display = if ($cv.DisplayVersion) { [string]$cv.DisplayVersion } else { [string]$cv.ReleaseId }
        Edition = [string]$cv.EditionID
    }
}

function Restart-Explorer {
    Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1500
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
}

# ---- machine facts and the hardware fingerprint ----------------------------
function Get-MachineFacts {
    $ErrorActionPreference = 'SilentlyContinue'
    $f = @{}
    $cs = Get-CimInstance Win32_ComputerSystem
    $f.Name = if ($cs.Name) { [string]$cs.Name } else { $env:COMPUTERNAME }
    $f.InDomain = [bool]$cs.PartOfDomain
    $f.Domain = [string]$cs.Domain
    $f.Workgroup = [string]$cs.Workgroup
    $f.Manufacturer = [string]$cs.Manufacturer
    $f.ModelRaw = [string]$cs.Model
    $f.Model = Clean $cs.Model
    $bs = [string](Get-CimInstance Win32_BaseBoard).SerialNumber
    if ($bs -match 'Default string|To be filled|None') { $bs = '' }
    $f.Serial = Clean $bs
    $f.BiosSerial = Get-RealSerial (Get-CimInstance Win32_BIOS).SerialNumber
    $f.UUID = Clean (Get-CimInstance Win32_ComputerSystemProduct).UUID
    $a = Get-NetAdapter -Physical | Where-Object { $_.MacAddress } |
         Sort-Object @{ e = { if ($_.MediaType -eq '802.3') { 0 } else { 1 } } }, ifIndex | Select-Object -First 1
    $f.MAC = if ($a) { Clean ($a.MacAddress -replace '[^A-Fa-f0-9]', '') } else { '-' }
    $f.NIC = if ($a) { Clean $a.Name } else { '-' }
    $f.TZ = (Get-TimeZone).Id
    $d = [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name srvcomment).srvcomment
    $f.Desc = if ($d) { $d } else { '(not set)' }
    # Fingerprint: onboard NIC MAC first, then system UUID, then board serial.
    # Virtual adapters (VMware, VirtualBox, Hyper-V, Tailscale) are excluded by
    # -Physical: their MACs are identical on every PC that has them.
    $f.FP = $null; $f.FPType = $null
    if ($f.MAC -and $f.MAC -ne '-') { $f.FP = $f.MAC; $f.FPType = 'MAC' }
    elseif ($f.UUID -and $f.UUID -ne '-') { $f.FP = $f.UUID; $f.FPType = 'UUID' }
    elseif ($f.Serial -and $f.Serial -ne '-') { $f.FP = $f.Serial; $f.FPType = 'SERIAL' }
    return $f
}

# Why this PC may not be renamed, if at all.
function Get-RenameGuard {
    param([bool]$ForceDomain = $false)
    $g = @{ Blocked = $false; Short = ''; Reason = '' }
    foreach ($m in $Cfg.ProtectedMacs) {
        if ($m -and $m -ieq $Facts.MAC) { $g.Blocked = $true; $g.Short = 'protected PC'; $g.Reason = "protected MAC $m" }
    }
    foreach ($n in $Cfg.ProtectedNames) {
        if ($n -and $n -ieq $Facts.Name) { $g.Blocked = $true; $g.Short = 'protected PC'; $g.Reason = "protected name $n" }
    }
    if ($Facts.InDomain -and -not $ForceDomain) {
        if (-not $g.Blocked) { $g.Short = 'domain-joined'; $g.Reason = "joined to domain $($Facts.Domain) - tick 'Domain PC' to rename with domain credentials" }
        $g.Blocked = $true
    }
    if ($Cfg.Remote -and -not $Cfg.DbExplicit) {
        if (-not $g.Blocked) {
            $g.Short = 'no registry'
            $g.Reason = 'launched from the internet with no name registry reachable - set a registry file in Names & settings to enable renaming'
        }
        $g.Blocked = $true
    }
    if (-not $Facts.FP) {
        if (-not $g.Blocked) { $g.Short = 'no hardware ID'; $g.Reason = 'no physical NIC MAC, no system UUID and no usable board serial - refusing to guess' }
        $g.Blocked = $true
    }
    return $g
}

# ---- name registry (TQNY-Names.csv, shared with TQNY-Classic.bat) -----------
$CsvHeader = 'Number,AssignedName,Fingerprint,FpType,OldName,Model,Serial,FirstSeenUTC,LastSeenUTC,Tech,Site'

function Get-RegRows {
    $db = $Cfg.DbFile
    if (-not (Test-Path -LiteralPath $db)) { return @() }
    $names = $CsvHeader.Split(',')
    $rows = New-Object System.Collections.ArrayList
    $lines = @(Get-Content -LiteralPath $db -ErrorAction SilentlyContinue)
    for ($k = 1; $k -lt $lines.Count; $k++) {
        $ln = [string]$lines[$k]
        if (-not $ln.Trim()) { continue }
        $p = $ln.Split(',')
        $o = [ordered]@{}
        for ($i = 0; $i -lt 11; $i++) { $o[$names[$i]] = if ($i -lt $p.Count) { $p[$i].Trim() } else { '' } }
        [void]$rows.Add([pscustomobject]$o)
    }
    return $rows.ToArray()
}

function Lock-Registry {
    $dbDir = Split-Path -Parent $Cfg.DbFile
    if (-not $dbDir -or -not (Test-Path -LiteralPath $dbDir)) {
        Fail "The registry folder does not exist: $dbDir"
        return $false
    }
    $lock = Join-Path $dbDir '.tqny.lock'
    # cmd's md is atomic: it fails if the folder already exists. That is the
    # same lock TQNY-Classic.bat uses, so the two tools can share a registry.
    for ($t = 1; $t -le [int]$Cfg.LockTries; $t++) {
        & cmd.exe /c md "$lock" 2>$null
        if ($LASTEXITCODE -eq 0) { $sync.LockHeld = $lock; return $true }
        if ($t -eq 1) {
            $li = Get-Item -LiteralPath $lock -ErrorAction SilentlyContinue
            if ($li -and ((Get-Date) - $li.CreationTime).TotalMinutes -gt 10) {
                Warn 'Breaking a stale lock older than 10 minutes.'
                Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }
        }
        Start-Sleep -Seconds 1
    }
    Fail 'Another copy of this tool is using the registry. Try again shortly.'
    return $false
}

function Unlock-Registry {
    if ($sync.LockHeld) { Remove-Item -LiteralPath $sync.LockHeld -Recurse -Force -ErrorAction SilentlyContinue }
    $sync.LockHeld = $null
}

# Rewrite the CSV through a filter. $Map gets the split fields and the raw
# line, and returns the line to keep (or $null to drop it).
function Update-RegFile {
    param([scriptblock]$Map)
    $db = $Cfg.DbFile
    if (-not (Test-Path -LiteralPath $db)) { return }
    $lines = @(Get-Content -LiteralPath $db)
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($CsvHeader)
    for ($k = 1; $k -lt $lines.Count; $k++) {
        $ln = [string]$lines[$k]
        if (-not $ln.Trim()) { continue }
        $r = & $Map ($ln.Split(',')) $ln
        if ($null -ne $r) { [void]$out.Add($r) }
    }
    $tmp = "$db.tmp"
    Set-Content -LiteralPath $tmp -Value $out.ToArray() -Encoding ASCII
    Move-Item -LiteralPath $tmp -Destination $db -Force
}

function Format-RegField { param($v) $s = ([string]$v).Replace(',', ' ').Trim(); if ($s) { $s } else { '-' } }

function Add-RegRow {
    param([string]$Num, [string]$Name, [string]$FpVal, [string]$FpType, [string]$Old, [string]$Model, [string]$Serial)
    $now = Get-UtcNow
    $vals = @($Num, $Name, $FpVal, $FpType, $Old, $Model, $Serial, $now, $now, $Cfg.Tech, $Cfg.Site) | ForEach-Object { Format-RegField $_ }
    Add-Content -LiteralPath $Cfg.DbFile -Value ($vals -join ',') -Encoding ASCII
}

function Get-PaddedName { param([int]$N) if ($N -ge 100) { "$($Cfg.Prefix)-$N" } else { '{0}-{1:D2}' -f $Cfg.Prefix, $N } }

# Is a name unused on this network? Same test as v3.x: does it resolve?
function Test-NameFree {
    param([string]$Name)
    if ($Name -ieq $Facts.Name) { return $true }
    try { [void][System.Net.Dns]::GetHostEntry($Name); return $false } catch { return $true }
}

function Test-ComputerName {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { return 'Use only letters, digits and hyphens, and start with a letter or digit. No spaces or underscores.' }
    if ($Name.EndsWith('-')) { return 'A computer name cannot end with a hyphen.' }
    if ($Name -match '^[0-9]+$') { return 'Windows rejects an all-numeric computer name.' }
    if ($Name.Length -gt 15) { return "$Name is $($Name.Length) characters. The maximum is 15." }
    return $null
}

function Test-Prefix {
    param([string]$P)
    $P = $P.Trim().TrimEnd('-')
    if (-not $P) { return 'The prefix is empty.' }
    if ($P -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { return 'Use only letters, digits and hyphens, and start with a letter or digit.' }
    if ($P -match '^[0-9]+$') { return 'An all-digit prefix is rejected by Windows.' }
    if ($P.Length -gt 12) { return "The prefix is $($P.Length) characters. Maximum is 12, because a computer name cannot exceed 15." }
    return $null
}

# Two gates must agree before a number is used: the registry file, and the
# live network. Numbering is per prefix. Free-form names are stored as 0.
function Invoke-NameAllocation {
    param([bool]$Apply = $false, [string]$CustomName = '', [string]$ForceNum = '', [bool]$ForceDomain = $false)
    $res = @{ Target = $null; N = $null; Ok = $false }
    $g = Get-RenameGuard -ForceDomain $ForceDomain
    Head 'Protection and domain check'
    if ($g.Blocked) { Warn "Rename is blocked: $($g.Reason)" } else { Ok 'Not protected, not domain-locked. Rename is permitted.' }
    if (-not $Facts.FP) { return $res }

    Head 'Name allocation'
    Info "Prefix: $($Cfg.Prefix)    Registry: $($Cfg.DbFile)"
    if (-not (Lock-Registry)) { return $res }
    try {
        $db = $Cfg.DbFile
        if (-not (Test-Path -LiteralPath $db) -and $Apply) {
            try { Set-Content -LiteralPath $db -Value $CsvHeader -Encoding ASCII -ErrorAction Stop; Ok 'Created a new registry file.' }
            catch { Warn 'Cannot write the registry file. The location is read-only.' }
        }
        $pfx = "$($Cfg.Prefix)-"
        $used = @{}; $foundNum = $null; $foundName = $null; $foundOther = $null
        foreach ($r in (Get-RegRows)) {
            $same = $r.AssignedName.StartsWith($pfx, [StringComparison]::OrdinalIgnoreCase) -or $r.Number -eq '0'
            $num = 0
            if ($same -and [int]::TryParse($r.Number, [ref]$num) -and $num -gt 0) { $used[$num] = $true }
            if ($r.Fingerprint -ieq $Facts.FP) {
                if ($same) { $foundNum = $r.Number; $foundName = $r.AssignedName } else { $foundOther = $r.AssignedName }
            }
        }
        $target = $null; $n = $null
        if ($CustomName) {
            # A typed name gets the same safety as a numbered one.
            $bad = Test-ComputerName $CustomName
            $other = @(Get-RegRows | Where-Object { $_.AssignedName -ieq $CustomName -and $_.Fingerprint -ine $Facts.FP })
            if ($bad) { Fail $bad }
            elseif ($other.Count) { Fail "$CustomName is already in the name registry (another PC, hardware ID $($other[0].Fingerprint)). Pick another." }
            elseif (-not (Test-NameFree $CustomName)) { Fail "$CustomName already answers on this network. Pick another." }
            else { $target = $CustomName; $n = 0; Ok "Using the name you typed: $CustomName - valid and free." }
        } else {
            if ($foundOther) {
                Warn "This PC is already registered as $foundOther, under another prefix."
                Info "        It will be given a new $($Cfg.Prefix) name and the old entry released."
            }
            if ($foundName) {
                $target = $foundName; $n = $foundNum
                Ok "Already in the registry as $target, number $foundNum. Reusing it - no new number is consumed."
            } elseif ($ForceNum) {
                $n = [int]$ForceNum
                $cand = Get-PaddedName $n
                if ($cand.Length -gt 15) { Fail "$cand is longer than 15 characters. Use a shorter prefix." }
                elseif ($used.ContainsKey($n)) { Fail "Number $n is already used in the registry. Pick another." }
                elseif (-not (Test-NameFree $cand)) { Fail "$cand already answers on this network. Pick another." }
                else { $target = $cand; Ok "Forced number $n gives $target." }
            } else {
                for ($i = 1; $i -le 500; $i++) {
                    Test-Cancel
                    if ($used.ContainsKey($i)) { continue }
                    $cand = Get-PaddedName $i
                    if ($cand.Length -gt 15) { Fail "$cand is longer than 15 characters. Use a shorter prefix."; break }
                    if (-not (Test-NameFree $cand)) {
                        Warn "$cand already answers on this network. Reserving it and moving on."
                        if ($Apply -and (Test-Path -LiteralPath $db)) { Add-RegRow "$i" $cand 'RESERVED-external' 'LAN' '-' '-' '-' }
                        $used[$i] = $true
                        continue
                    }
                    $target = $cand; $n = $i
                    Ok "Next free number is $i, giving $target."
                    break
                }
                if (-not $target -and $i -gt 500) { Fail 'No free number below 500. Check the registry file.' }
            }
        }
        if ($target) {
            if ($target -ieq $Facts.Name) { Ok 'The name is already correct. Nothing to rename.' }
            else { Info "Proposed rename:  $($Facts.Name)  ->  $target" }
        }
        if ($Apply -and $target) {
            if ($g.Blocked) {
                Info '[SKIP] Not claiming a number. This machine is blocked from rename.'
            } elseif ($CustomName) {
                $fp = $Facts.FP
                Update-RegFile { param($p, $ln) if ($p.Count -gt 2 -and $p[2].Trim() -ieq $fp) { $null } else { $ln } }
                Add-RegRow '0' $target $Facts.FP $Facts.FPType $Facts.Name $Facts.Model $Facts.Serial
                Ok "Recorded $target in the registry."
            } elseif ($null -ne $foundNum) {
                $fp = $Facts.FP; $now = Get-UtcNow; $tech = Format-RegField $Cfg.Tech; $site = Format-RegField $Cfg.Site
                Update-RegFile {
                    param($p, $ln)
                    if ($p.Count -gt 2 -and $p[2].Trim() -ieq $fp) {
                        $q = @($p) + @('', '', '', '', '', '', '', '', '', '', '')
                        (@($q[0..7]) + @($now, $tech, $site)) -join ','
                    } else { $ln }
                }
                Ok "Registry row refreshed for $target."
            } else {
                if ($foundOther) {
                    $fp = $Facts.FP
                    Update-RegFile { param($p, $ln) if ($p.Count -gt 2 -and $p[2].Trim() -ieq $fp) { $null } else { $ln } }
                }
                Add-RegRow "$n" $target $Facts.FP $Facts.FPType $Facts.Name $Facts.Model $Facts.Serial
                Ok "Claimed $target in the registry."
            }
        } elseif ($target) {
            Info "[PREVIEW] Would claim $target. The registry file is NOT modified."
        }
        $res.Target = $target; $res.N = $n; $res.Ok = [bool]$target; $res.Blocked = $g.Blocked
    } finally {
        Unlock-Registry
    }
    return $res
}

function Invoke-RenamePC {
    param([string]$Target, [pscredential]$Cred, [bool]$ForceDomain = $false)
    Head 'Rename'
    $g = Get-RenameGuard -ForceDomain $ForceDomain
    if (-not $Target) { Info '[SKIP] No name was allocated, so there is nothing to rename.'; return $false }
    if ($Target -ieq $Facts.Name) { Info "[SKIP] This PC is already named $Target."; return $false }
    if ($g.Blocked) { Warn "[BLOCKED] Rename refused. Reason: $($g.Reason)"; return $false }
    try {
        if ($Cred) { Rename-Computer -NewName $Target -DomainCredential $Cred -Force -ErrorAction Stop }
        else { Rename-Computer -NewName $Target -Force -ErrorAction Stop }
        Done "Renamed $($Facts.Name) to $Target (active after a restart)"
        $sync.RebootNeeded = $true
        $sync.NewName = $Target
        return $true
    } catch {
        Warn "Rename-Computer failed: $($_.Exception.Message)"
        Info 'Trying the WMI fallback...'
        try {
            $r = Get-CimInstance Win32_ComputerSystem | Invoke-CimMethod -MethodName Rename -Arguments @{ Name = $Target } -ErrorAction Stop
            if ($r.ReturnValue -eq 0) {
                Done "Renamed $($Facts.Name) to $Target via WMI (active after a restart)"
                $sync.RebootNeeded = $true; $sync.NewName = $Target
                return $true
            }
            Fail "WMI rename returned code $($r.ReturnValue)."
        } catch { Fail "Could not rename this PC: $($_.Exception.Message)" }
        return $false
    }
}

function Invoke-ReleaseNumber {
    Head "Release this machine's number"
    if (-not $Facts.FP) { Fail 'No hardware ID.'; return }
    if (-not (Lock-Registry)) { return }
    try {
        $mine = @(Get-RegRows | Where-Object { $_.Fingerprint -ieq $Facts.FP })
        if ($mine.Count -eq 0) { Info '[SKIP] This machine is not in the registry. Nothing to release.'; return }
        $fp = $Facts.FP
        Update-RegFile { param($p, $ln) if ($p.Count -gt 2 -and $p[2].Trim() -ieq $fp) { $null } else { $ln } }
        foreach ($m in $mine) { Ok "Released $($m.AssignedName), number $($m.Number). That number is free again." }
        Info 'The computer name itself was NOT changed.'
    } finally { Unlock-Registry }
}

function Show-Registry {
    Head 'Name registry'
    Info "File: $($Cfg.DbFile)"
    if (-not (Test-Path -LiteralPath $Cfg.DbFile)) { Info 'The registry file does not exist yet. It is created on the first rename.'; return }
    $rows = @(Get-RegRows)
    $rows | Out-Table -Property Number, AssignedName, Fingerprint, OldName, Model, FirstSeenUTC, LastSeenUTC, Tech, Site
    Info "$($rows.Count) row(s)."
}

# ---- internet check, READ ONLY ---------------------------------------------
function Test-Internet {
    Head 'Internet check - read only, nothing is changed'
    $r = @{ NIC = '-'; Desc = '-'; IPv4 = '-'; GW = '-'; DNS = '-'; DHCP = '-'; Cat = '-'; Speed = '-'; DnsOk = 'NO'; WebOk = 'NO' }
    $a = Get-ActiveAdapter
    if (-not $a) {
        Fail 'No physical network adapter is connected.'
        Info '        Check the cable or connect Wi-Fi, then run this again.'
        $sync.LastNet = $r
        return $r
    }
    $c = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
    $r.NIC = $a.Name; $r.Desc = $a.InterfaceDescription; $r.Speed = $a.LinkSpeed
    if ($c.IPv4Address) { $r.IPv4 = [string](@($c.IPv4Address)[0].IPAddress) }
    if ($c.IPv4DefaultGateway) { $r.GW = [string](@($c.IPv4DefaultGateway)[0].NextHop) }
    $dns = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
    if ($dns.Count) { $r.DNS = $dns -join ' ' }
    $r.DHCP = [string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
    $r.Cat = [string](Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).NetworkCategory
    Info "Adapter    : $($r.NIC)   $($r.Desc)"
    Info "Link speed : $($r.Speed)"
    Info "IPv4       : $($r.IPv4)      DHCP: $($r.DHCP)"
    Info "Gateway    : $($r.GW)"
    Info "DNS        : $($r.DNS)"
    Info "Profile    : $($r.Cat)"
    if ($r.IPv4 -eq '-') { Fail 'No IPv4 address. This PC got nothing from DHCP.' }
    elseif ($r.IPv4 -like '169.254.*') { Fail "$($r.IPv4) is a self-assigned address. DHCP is not answering." }
    else { Ok 'Has a real IPv4 address.' }
    if ($r.GW -eq '-') { Fail 'No default gateway. This PC cannot leave the local network.' }
    elseif (Test-Ping $r.GW 1000 2) { Ok "Gateway $($r.GW) replies." }
    else { Fail "Gateway $($r.GW) does not reply." }
    if (Test-Ping '1.1.1.1' 1500 2) { Ok 'Internet routing works. 1.1.1.1 replies.' }
    else { Fail 'Cannot reach 1.1.1.1. Routing is broken or the line is down.' }
    try { [void][System.Net.Dns]::GetHostEntry('www.microsoft.com'); $r.DnsOk = 'YES'; Ok 'DNS resolution works.' }
    catch { Fail 'DNS is not resolving names. Check the DNS servers listed above.' }
    $t = Get-WebText 'http://www.msftconnecttest.com/connecttest.txt' 8000
    if ($t -and $t -match 'Microsoft Connect Test') { $r.WebOk = 'YES'; Ok 'Real internet access confirmed.' }
    else { Fail 'No usable internet access. The web test failed.' }
    if ($r.DnsOk -eq 'YES' -and $r.WebOk -eq 'YES') { Log '  INTERNET STATUS: GOOD' 'ok' }
    else { Log '  INTERNET STATUS: PROBLEM. See the FAIL lines above. Nothing was changed.' 'fail' }
    $sync.LastNet = $r
    return $r
}

# ---- network scan, READ ONLY -------------------------------------------------
function Get-ScanBase {
    param([string]$Base)
    $a = Get-ActiveAdapter
    if (-not $a) { Fail 'No connected physical network adapter. Cannot scan.'; return $null }
    $localIP = [string](@((Get-NetIPConfiguration -InterfaceIndex $a.ifIndex).IPv4Address)[0].IPAddress)
    if (-not $localIP) { Fail 'This PC has no IPv4 address, so there is no network to scan.'; return $null }
    if ([string]::IsNullOrWhiteSpace($Base)) { $Base = ($localIP -split '\.')[0..2] -join '.' }
    $Base = $Base.Trim().TrimEnd('.')
    if ($Base -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}$') { Fail "Subnet base '$Base' should look like 192.168.1"; return $null }
    return @{ Base = $Base; LocalIP = $localIP; Adapter = $a }
}

function Invoke-PingSweep {
    param([string]$Base)
    $tasks = 1..254 | ForEach-Object { (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$Base.$_", 700) }
    try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch { }
    $alive = @{}
    for ($i = 0; $i -lt 254; $i++) {
        $t = $tasks[$i]
        if ($t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { $alive["$Base.$($i + 1)"] = [int]$t.Result.RoundtripTime }
    }
    return $alive
}

function Invoke-NetScan {
    param([string]$Base)
    Head 'Scan the network - read only, nothing is changed'
    $s = Get-ScanBase $Base
    if (-not $s) { return }
    Info "Scanning $($s.Base).1-254 from $($s.LocalIP) on $($s.Adapter.Name) ..."
    Set-Progress -1 'Pinging 254 addresses'
    $alive = Invoke-PingSweep $s.Base
    if ($alive.Count -eq 0) { Info '0 host(s) answered.'; return }
    Test-Cancel
    Set-Progress -1 'Asking each host for its name'
    # NetBIOS node-status query sent from the REAL nic. nbtstat binds to the
    # wrong adapter on PCs with VMware/VirtualBox, so we do it ourselves.
    $names = @{}
    $pkt = [byte[]]@(0xA1, 0xA2, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x20, 0x43, 0x4B, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
        0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
        0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x21, 0x00, 0x01)
    $socks = @(); $rx = @{}
    foreach ($ip in @($alive.Keys)) {
        try {
            $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($s.LocalIP), 0)
            $u = New-Object System.Net.Sockets.UdpClient($ep)
            [void]$u.Send($pkt, $pkt.Length, $ip, 137)
            $rx[$ip] = $u.ReceiveAsync(); $socks += $u
        } catch { }
    }
    if ($rx.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll(@($rx.Values), 2500) } catch { }
        foreach ($ip in @($rx.Keys)) {
            $t = $rx[$ip]
            if ($t.Status -ne 'RanToCompletion') { continue }
            $data = $t.Result.Buffer
            if (-not $data -or $data.Length -lt 57) { continue }
            $count = $data[56]
            for ($k = 0; $k -lt $count; $k++) {
                $off = 57 + ($k * 18)
                if ($off + 17 -ge $data.Length) { break }
                if ($data[$off + 15] -eq 0x00 -and -not (($data[$off + 16] -band 0x80) -ne 0)) {
                    $nm = [System.Text.Encoding]::ASCII.GetString($data, $off, 15).Trim()
                    if ($nm) { $names[$ip] = $nm }
                    break
                }
            }
        }
    }
    foreach ($u in $socks) { try { $u.Close() } catch { } }
    # Reverse DNS for anything without a NetBIOS name, capped at 2 seconds.
    $dnsTasks = @{}
    foreach ($ip in $alive.Keys) { if (-not $names.ContainsKey($ip)) { try { $dnsTasks[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch { } } }
    if ($dnsTasks.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll(@($dnsTasks.Values), 2000) } catch { }
        foreach ($ip in @($dnsTasks.Keys)) {
            $t = $dnsTasks[$ip]
            if ($t.Status -eq 'RanToCompletion' -and $t.Result.HostName) { $names[$ip] = ($t.Result.HostName -split '\.')[0] }
        }
    }
    $macs = @{}
    foreach ($line in (arp -a)) { if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f-]{17})') { $macs[$matches[1]] = $matches[2].ToUpper() } }
    $rows = foreach ($ip in ($alive.Keys | Sort-Object { [int]($_ -split '\.')[3] })) {
        $self = ($ip -eq $s.LocalIP)
        $nm = if ($self) { $env:COMPUTERNAME } elseif ($names[$ip]) { $names[$ip] } else { '-' }
        $tag = ''
        if ($self) { $tag = '<< THIS PC' } elseif ($nm -like "$($Cfg.Prefix)-*") { $tag = "<< $($Cfg.Prefix) name in use" }
        [pscustomobject]@{
            IP = $ip; Name = $nm
            MAC = if ($self) { '(this pc)' } elseif ($macs[$ip]) { $macs[$ip] } else { '-' }
            ms = $alive[$ip]; Note = $tag
        }
    }
    $rows | Out-Table
    Ok "$($alive.Count) host(s) answered."
    Dim 'Names come from NetBIOS or DNS and are best-effort. IP, MAC and ping are always reliable.'
}

# ---- network visibility -------------------------------------------------------
function Show-VisibilityPlan {
    $a = Get-ActiveAdapter
    $cat = if ($a) { [string](Get-NetConnectionProfile -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).NetworkCategory } else { '-' }
    Info 'Makes this PC visible on the network:'
    Info "  - sets the connected physical adapter to Private (it is $cat now)"
    Info '  - enables Network Discovery and File and Printer Sharing for Private only'
    Info '  - sets the discovery services to start automatically'
    Info 'Public stays locked down. Existing shared folders are never touched. SMB1 is not enabled.'
}

function Enable-NetworkVisibility {
    Head 'Network visibility - be seen on the network'
    try {
        Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            Set-NetConnectionProfile -InterfaceIndex $_.ifIndex -NetworkCategory Private -ErrorAction Stop
        }
        Done 'Connected adapter set to the Private network profile'
    } catch { Fail "Could not set the network profile to Private: $($_.Exception.Message)" }
    # Group IDs, not display names: display names are translated on Arabic Windows.
    $fwOk = $true
    foreach ($grp in '@FirewallAPI.dll,-32752', '@FirewallAPI.dll,-28502') {
        try { Get-NetFirewallRule -Group $grp -ErrorAction Stop | Where-Object { $_.Profile -match 'Private' } | Set-NetFirewallRule -Enabled True -ErrorAction Stop }
        catch { $fwOk = $false }
    }
    if ($fwOk) { Done 'Network Discovery and File and Printer Sharing enabled for Private' }
    else {
        Warn 'Group IDs failed. Falling back to English rule-group names...'
        # A single argument string reaches netsh verbatim, quotes included.
        $p1 = Start-Process netsh.exe -ArgumentList 'advfirewall firewall set rule group="Network Discovery" new enable=Yes' -Wait -PassThru -WindowStyle Hidden
        $p2 = Start-Process netsh.exe -ArgumentList 'advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes' -Wait -PassThru -WindowStyle Hidden
        if ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) { Done 'Discovery firewall rules enabled via netsh' } else { Fail 'Could not enable the discovery firewall rules.' }
    }
    $bad = $false
    foreach ($svc in 'FDResPub', 'fdPHost', 'SSDPSRV', 'upnphost', 'LanmanServer', 'LanmanWorkstation') {
        try { Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop; Start-Service -Name $svc -ErrorAction SilentlyContinue } catch { $bad = $true }
    }
    if ($bad) { Warn 'One or more discovery services could not be reconfigured.' } else { Done 'Discovery services set to Automatic and started' }
    Ok 'Existing shared folders left untouched.'
}

function Show-DiscoveryServices {
    Head 'Discovery services'
    Info 'These must run for this PC to appear under Network on other PCs.'
    Get-Service FDResPub, fdPHost, SSDPSRV, upnphost, LanmanServer, LanmanWorkstation -ErrorAction SilentlyContinue |
        Out-Table -Property Name, Status, StartType, DisplayName
}

function Set-NetProfile {
    param([string]$Category)
    Head "Set network profile to $Category"
    try {
        Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            Set-NetConnectionProfile -InterfaceIndex $_.ifIndex -NetworkCategory $Category -ErrorAction Stop
            Done "$($_.Name) set to the $Category network profile"
        }
    } catch { Fail $_.Exception.Message }
}

# ---- remote desktop and connection details ----------------------------------
function Get-RdpEnabled {
    $d = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -ErrorAction SilentlyContinue).fDenyTSConnections
    return ($d -eq 0)
}

function Set-RemoteDesktop {
    param([bool]$On)
    Head ('Remote Desktop ' + $(if ($On) { 'ON' } else { 'OFF' }))
    $ed = Get-WindowsEdition
    if ($On -and $ed.Edition -match 'Core|Home') { Warn 'This is a Home edition. Windows Home cannot accept Remote Desktop connections. Use AnyDesk / RustDesk / Quick Assist instead.' }
    try {
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value ($(if ($On) { 0 } else { 1 })) -ErrorAction Stop
        Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction Stop | Set-NetFirewallRule -Enabled ($(if ($On) { 'True' } else { 'False' })) -ErrorAction Stop
        if ($On) { Done 'Remote Desktop enabled and allowed through the firewall' } else { Done 'Remote Desktop disabled' }
    } catch { Fail "Could not change Remote Desktop: $($_.Exception.Message)" }
}

function Show-ConnectionInfo {
    Head 'How to reach this PC'
    Info "Computer name : $env:COMPUTERNAME"
    Info "Logged on as  : $env:USERDOMAIN\$env:USERNAME"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } | Sort-Object InterfaceIndex |
        ForEach-Object { Info ("IP address    : {0}  on {1}" -f $_.IPAddress, $_.InterfaceAlias) }
    Info ('Remote Desktop: ' + $(if (Get-RdpEnabled) { 'ENABLED' } else { 'disabled' }))
    $p = Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.IPv4Connectivity -ne 'Disconnected' } | Select-Object -First 1
    if ($p) { Info "Network profile: $($p.NetworkCategory)" }
    $pub = Get-WebText 'https://api.ipify.org' 5000
    if ($pub) { Info "Public IP     : $pub" }
    Info ''
    Info 'Give the customer the computer name or the IP to let you connect.'
}


# ---- IP / DNS settings --------------------------------------------------------
function ConvertTo-Mask {
    param([string]$m)
    $m = $m.Trim().TrimStart('/')
    if ($m -match '^\d{1,2}$' -and [int]$m -le 32) {
        $bits = ('1' * [int]$m).PadRight(32, '0')
        return ((0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.')
    }
    return $m
}

function Show-AdapterDetail {
    Head 'Network adapters'
    Get-NetAdapter -ErrorAction SilentlyContinue | Sort-Object ifIndex | Out-Table -Property Name, Status, LinkSpeed, MacAddress, InterfaceDescription
    Head 'IP configuration'
    foreach ($c in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        $ip = @($c.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', '
        $gw = @($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', '
        $dns = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ', '
        $dh = [string](Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
        Info ("{0}" -f $c.InterfaceAlias)
        Dim ("   IPv4 {0}   gateway {1}   DNS {2}   DHCP {3}" -f $(if ($ip) { $ip } else { '-' }), $(if ($gw) { $gw } else { '-' }), $(if ($dns) { $dns } else { '-' }), $dh)
    }
}

function Get-AdapterIpInfo {
    param([string]$Adapter)
    $a = Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue
    if (-not $a) { return $null }
    $c = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue
    $ip = @($c.IPv4Address)[0]
    return @{
        IP   = if ($ip) { [string]$ip.IPAddress } else { '' }
        Mask = if ($ip) { ConvertTo-Mask ([string]$ip.PrefixLength) } else { '255.255.255.0' }
        GW   = [string](@($c.IPv4DefaultGateway)[0].NextHop)
        DNS  = @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
        DHCP = [string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
    }
}

function Set-AdapterAddress {
    param([string]$Adapter, [string]$Mode, [string]$Ip, [string]$Mask, [string]$Gw, [string]$Dns1, [string]$Dns2)
    Head "IP settings for $Adapter"
    if (-not (Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue)) { Fail "No adapter named $Adapter."; return }
    if ($Mode -eq 'DHCP') {
        $c = Invoke-Native netsh.exe @('interface', 'ipv4', 'set', 'address', $Adapter, 'dhcp')
        $d = Invoke-Native netsh.exe @('interface', 'ipv4', 'set', 'dnsservers', $Adapter, 'dhcp')
        if ($c -eq 0) { Done "$Adapter set to get its IP automatically (DHCP)" } else { Warn 'netsh reported a problem setting DHCP (it may already be on DHCP).' }
        if ($d -eq 0) { Ok 'DNS set to automatic.' }
        Start-Sleep -Seconds 3
        Invoke-Native ipconfig.exe @('/renew', $Adapter) -Quiet | Out-Null
        return
    }
    $Mask = ConvertTo-Mask $Mask
    foreach ($pair in @(@('IP', $Ip), @('Subnet mask', $Mask))) {
        if (-not (Test-IPv4 $pair[1])) { Fail "$($pair[0]) '$($pair[1])' is not a valid IPv4 address."; return }
    }
    if ($Gw -and -not (Test-IPv4 $Gw)) { Fail "Gateway '$Gw' is not a valid IPv4 address."; return }
    $args1 = @('interface', 'ipv4', 'set', 'address', $Adapter, 'static', $Ip, $Mask)
    if ($Gw) { $args1 += @($Gw, '1') }
    $c = Invoke-Native netsh.exe $args1
    if ($c -eq 0) { Done "$Adapter set to static IP $Ip / $Mask, gateway $(if ($Gw) { $Gw } else { 'none' })" }
    else { Fail 'netsh could not set the static address. Is the IP already used by another adapter?'; return }
    $dns = @($Dns1, $Dns2) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }
    if ($dns.Count) { Set-AdapterDns -Adapter $Adapter -Servers $dns }
}

function Set-AdapterDns {
    param([string]$Adapter, [string[]]$Servers)
    Head "DNS for $Adapter"
    try {
        if (-not $Servers -or $Servers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceAlias $Adapter -ResetServerAddresses -ErrorAction Stop
            Done "$Adapter DNS set back to automatic (from DHCP)"
        } else {
            foreach ($s in $Servers) { if (-not (Test-IPv4 $s)) { Fail "DNS server '$s' is not a valid IPv4 address."; return } }
            Set-DnsClientServerAddress -InterfaceAlias $Adapter -ServerAddresses $Servers -ErrorAction Stop
            Done "$Adapter DNS set to $($Servers -join ', ')"
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    } catch { Fail $_.Exception.Message }
}

# ---- network repairs -----------------------------------------------------------
function Invoke-NetRepair {
    param([string[]]$What)
    Head 'Network repair'
    if ($What -contains 'flush') {
        if ((Invoke-Native ipconfig.exe @('/flushdns') -Quiet) -eq 0) { Done 'DNS cache flushed' } else { Fail 'Could not flush DNS.' }
    }
    if ($What -contains 'arp') {
        Invoke-Native netsh.exe @('interface', 'ip', 'delete', 'arpcache') -Quiet | Out-Null
        Done 'ARP cache cleared'
    }
    if ($What -contains 'renew') {
        Info 'Releasing and renewing the IP address (the connection drops for a few seconds)...'
        Invoke-Native ipconfig.exe @('/release') -Quiet | Out-Null
        $c = Invoke-Native ipconfig.exe @('/renew') -Quiet
        if ($c -eq 0) { Done 'IP address released and renewed' } else { Warn 'Renew did not complete on every adapter. Disconnected adapters always report this.' }
    }
    if ($What -contains 'proxy') {
        Invoke-Native netsh.exe @('winhttp', 'reset', 'proxy') -Quiet | Out-Null
        try {
            Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyEnable' 0
            Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'ProxyServer'
            Remove-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' 'AutoConfigURL'
        } catch { }
        Done 'Proxy settings reset (WinHTTP and this user)'
    }
    if ($What -contains 'adapters') {
        Info 'Restarting the physical network adapters...'
        try { Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Not Present' } | Restart-NetAdapter -Confirm:$false -ErrorAction Stop; Done 'Network adapters restarted' }
        catch { Fail $_.Exception.Message }
    }
    if ($What -contains 'stack') {
        $c1 = Invoke-Native netsh.exe @('winsock', 'reset')
        $c2 = Invoke-Native netsh.exe @('int', 'ip', 'reset')
        Invoke-Native netsh.exe @('int', 'ipv6', 'reset') -Quiet | Out-Null
        if ($c1 -eq 0 -and $c2 -eq 0) { Done 'Winsock and TCP/IP stack reset (needs a restart)'; $sync.RebootNeeded = $true }
        else { Warn 'The stack reset reported a problem. A restart usually completes it anyway.'; $sync.RebootNeeded = $true }
    }
}

function Invoke-PingTool {
    param([string]$Target, [string]$Mode, [string]$Port)
    switch ($Mode) {
        'ping'  { Head "Ping $Target"; Invoke-Native ping.exe @('-n', '4', $Target) | Out-Null }
        'trace' { Head "Trace route to $Target"; Invoke-Native tracert.exe @('-d', '-h', '20', '-w', '800', $Target) | Out-Null }
        'dns'   { Head "DNS lookup $Target"; Invoke-Native nslookup.exe @($Target) | Out-Null }
        'port'  {
            Head "Port test $Target : $Port"
            $tc = New-Object System.Net.Sockets.TcpClient
            try {
                $t = $tc.ConnectAsync($Target, [int]$Port)
                if ($t.Wait(3000) -and $tc.Connected) { Ok "TCP port $Port on $Target is OPEN." }
                else { Fail "TCP port $Port on $Target did not answer within 3 seconds (closed or filtered)." }
            } catch { Fail "TCP port $Port on $Target is closed: $($_.Exception.InnerException.Message)" }
            finally { $tc.Close() }
        }
    }
}

function Show-PublicIp {
    Head 'Public IP'
    $ip = Get-WebText 'https://api.ipify.org' 6000
    if ($ip) { Ok "This network reaches the internet as $ip" } else { Fail 'Could not read the public IP (no internet, or the site is blocked).' }
}

# ---- Wi-Fi ------------------------------------------------------------------------
function Test-WlanLocation {
    param([string]$Text)
    if ($Text -match 'ms-settings:privacy-location') {
        Warn 'Windows 11 needs Location turned on before it shows Wi-Fi details to command-line tools.'
        Info '        Opening Settings > Privacy > Location. Turn on Location services, then try again.'
        Start-Process 'ms-settings:privacy-location'
        return $true
    }
    return $false
}

function Show-WifiStatus {
    Head 'Wi-Fi status'
    $t = Get-NativeText netsh.exe @('wlan', 'show', 'interfaces')
    if (Test-WlanLocation $t) { return }
    if (-not $t.Trim() -or $t -match 'not running') { Fail 'No Wi-Fi adapter, or the WLAN AutoConfig service is not running.'; return }
    foreach ($l in ($t -split "`n")) { if ($l.Trim()) { Dim $l.TrimEnd() } }
}

function Show-WifiNetworks {
    Head 'Wi-Fi networks in range'
    $t = Get-NativeText netsh.exe @('wlan', 'show', 'networks', 'mode=bssid')
    if (Test-WlanLocation $t) { return }
    $list = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($l in ($t -split "`n")) {
        if ($l -match '^\s*SSID\s+\d+\s*:\s*(.*)$') {
            $cur = [pscustomobject]@{ SSID = $matches[1].Trim(); Signal = 0; Auth = ''; Channel = '' }
            if (-not $cur.SSID) { $cur.SSID = '(hidden)' }
            [void]$list.Add($cur); continue
        }
        if (-not $cur) { continue }
        if ($l -match '(\d+)%') { $v = [int]$matches[1]; if ($v -gt $cur.Signal) { $cur.Signal = $v } }
        elseif (-not $cur.Auth -and $l -match ':\s*(WPA\S*|Open|Ouvert|WEP|.*Personal|.*Enterprise)\s*$') { $cur.Auth = $matches[1].Trim() }
    }
    if ($list.Count -eq 0) { Info 'No networks found. Is Wi-Fi switched on?'; return }
    $list | Sort-Object Signal -Descending | Out-Table -Property SSID, @{ n = 'Signal'; e = { "$($_.Signal)%" } }, Auth
    Ok "$($list.Count) network(s) in range."
}

function ConvertTo-XmlText { param([string]$s) return [System.Security.SecurityElement]::Escape($s) }

function Connect-Wifi {
    param([string]$Ssid, [string]$Password, [string]$Security = 'WPA2', [bool]$Hidden = $false)
    Head "Connect to Wi-Fi $Ssid"
    if (-not $Ssid) { Fail 'Type the network name (SSID).'; return }
    $auth = switch ($Security) { 'WPA3' { 'WPA3SAE' } 'Open' { 'open' } default { 'WPA2PSK' } }
    $enc = if ($Security -eq 'Open') { 'none' } else { 'AES' }
    if ($Security -ne 'Open' -and ($Password.Length -lt 8 -or $Password.Length -gt 63)) { Fail 'A WPA2/WPA3 password is 8 to 63 characters.'; return }
    $nb = if ($Hidden) { '<nonBroadcast>true</nonBroadcast>' } else { '' }
    $key = ''
    if ($Security -ne 'Open') {
        $key = '<sharedKey><keyType>passPhrase</keyType><protected>false</protected><keyMaterial>' + (ConvertTo-XmlText $Password) + '</keyMaterial></sharedKey>'
    }
    $x = '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' +
         '<name>' + (ConvertTo-XmlText $Ssid) + '</name><SSIDConfig><SSID><name>' + (ConvertTo-XmlText $Ssid) + '</name></SSID>' + $nb + '</SSIDConfig>' +
         '<connectionType>ESS</connectionType><connectionMode>auto</connectionMode><MSM><security><authEncryption>' +
         "<authentication>$auth</authentication><encryption>$enc</encryption><useOneX>false</useOneX></authEncryption>" + $key +
         '</security></MSM></WLANProfile>'
    $d = New-TempDir 'wifi'
    try {
        $file = Join-Path $d 'profile.xml'
        [IO.File]::WriteAllText($file, $x, (New-Object System.Text.UTF8Encoding $false))
        $c = Invoke-Native netsh.exe @('wlan', 'add', 'profile', $file, 'user=all')
        if ($c -ne 0) { Fail 'Windows refused the Wi-Fi profile.'; return }
        Done "Saved Wi-Fi network $Ssid"
        $c = Invoke-Native netsh.exe @('wlan', 'connect', $Ssid)
        if ($c -eq 0) { Ok 'Connection request sent. Give it a few seconds, then check the status.' } else { Warn 'Saved, but the connect request failed. Is the network in range?' }
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-WifiProfiles {
    $d = New-TempDir 'wifi'
    $list = New-Object System.Collections.ArrayList
    try {
        $t = Get-NativeText netsh.exe @('wlan', 'export', 'profile', 'key=clear', "folder=$d")
        if (Test-WlanLocation $t) { return @() }
        foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.xml -ErrorAction SilentlyContinue)) {
            try {
                [xml]$x = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
                $p = $x.WLANProfile
                [void]$list.Add([pscustomobject]@{
                    Name     = [string]$p.name
                    Security = [string]$p.MSM.security.authEncryption.authentication
                    Password = if ($p.MSM.security.sharedKey) { [string]$p.MSM.security.sharedKey.keyMaterial } else { '(none)' }
                    File     = $f.FullName
                    Xml      = [IO.File]::ReadAllText($f.FullName)
                })
            } catch { }
        }
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    return $list.ToArray()
}

function Show-WifiPasswords {
    Head 'Saved Wi-Fi networks and passwords'
    $p = @(Get-WifiProfiles)
    if ($p.Count -eq 0) { Info 'No saved Wi-Fi networks (or no Wi-Fi adapter).'; return }
    $p | Out-Table -Property Name, Security, Password
    Info "$($p.Count) saved network(s). Keep these private - they are the customer's passwords."
}

function Export-WifiProfiles {
    param([string]$Folder)
    Head "Back up Wi-Fi networks to $Folder"
    $p = @(Get-WifiProfiles)
    if ($p.Count -eq 0) { Info 'No saved Wi-Fi networks to back up.'; return 0 }
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $i = 0
    foreach ($w in $p) {
        $safe = ($w.Name -replace '[\\/:*?"<>|]', '_')
        if (-not $safe) { $safe = 'wifi' }
        $i++
        [IO.File]::WriteAllText((Join-Path $Folder ("Wi-Fi-{0:D2}-{1}.xml" -f $i, $safe)), $w.Xml, (New-Object System.Text.UTF8Encoding $false))
    }
    Done "Backed up $($p.Count) Wi-Fi network(s) with their passwords"
    return $p.Count
}

function Import-WifiProfiles {
    param([string]$Folder)
    Head "Restore Wi-Fi networks from $Folder"
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter *.xml -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { Fail 'No Wi-Fi profile .xml files in that folder.'; return }
    $d = New-TempDir 'wifi'
    $n = 0
    try {
        foreach ($f in $files) {
            $tmp = Join-Path $d 'p.xml'
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force
            $c = Invoke-Native netsh.exe @('wlan', 'add', 'profile', $tmp, 'user=all') -Quiet
            if ($c -eq 0) { $n++; Ok "Restored $($f.BaseName)" } else { Warn "Could not restore $($f.Name)" }
        }
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    if ($n) { Done "Restored $n Wi-Fi network(s)" }
}

function Remove-WifiProfile {
    param([string]$Name)
    Head "Forget Wi-Fi network $Name"
    $c = Invoke-Native netsh.exe @('wlan', 'delete', 'profile', $Name)
    if ($c -eq 0) { Done "Forgot Wi-Fi network $Name" } else { Fail "No saved network named $Name." }
}

function Show-WlanReport {
    Head 'Wi-Fi report'
    Info 'Building the report (last 3 days of Wi-Fi sessions, errors and disconnects)...'
    Invoke-Native netsh.exe @('wlan', 'show', 'wlanreport') -Quiet | Out-Null
    $f = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
    if (Test-Path -LiteralPath $f) { Start-Process $f; Ok 'Opened the Wi-Fi report in the browser.' } else { Fail 'The report was not created. Is there a Wi-Fi adapter?' }
}

# ---- sharing -----------------------------------------------------------------------
function Get-EveryoneName { try { (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0').Translate([System.Security.Principal.NTAccount]).Value } catch { 'Everyone' } }

function New-ShareUser {
    param([string]$User, [string]$Password)
    $u = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
    if ($u) { Ok "Local user $User already exists."; return $true }
    try {
        $sec = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $User -Password $sec -FullName $User -Description 'Network share access (TQNY-Setup)' -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $User -ErrorAction SilentlyContinue
        Done "Created local user $User for share access"
        return $true
    } catch { Fail "Could not create user $User : $($_.Exception.Message)"; return $false }
}

function New-TqnyShare {
    param([string]$Path, [string]$Name, [string]$Access = 'Everyone-Full', [string]$User, [string]$Password)
    Head "Create shared folder $Name"
    if (-not $Path -or -not $Name) { Fail 'Type a folder path and a share name.'; return }
    if ($Name -match '[\\/:*?"<>|]') { Fail 'A share name cannot contain \ / : * ? " < > |'; return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null; Ok "Created folder $Path" }
        if (Get-SmbShare -Name $Name -ErrorAction SilentlyContinue) { Fail "A share named $Name already exists on this PC."; return }
        $everyone = Get-EveryoneName
        switch ($Access) {
            'Everyone-Read' {
                New-SmbShare -Name $Name -Path $Path -ReadAccess $everyone -ErrorAction Stop | Out-Null
                & icacls.exe "$Path" /grant '*S-1-1-0:(OI)(CI)RX' | Out-Null
                $desc = 'Everyone, read only'
            }
            'User' {
                if (-not $User) { Fail 'Type the user name for the share.'; return }
                if (-not (New-ShareUser $User $Password)) { return }
                New-SmbShare -Name $Name -Path $Path -FullAccess "$env:COMPUTERNAME\$User" -ErrorAction Stop | Out-Null
                & icacls.exe "$Path" /grant "$($User):(OI)(CI)M" | Out-Null
                $desc = "user $User only, read and write"
            }
            default {
                New-SmbShare -Name $Name -Path $Path -FullAccess $everyone -ErrorAction Stop | Out-Null
                & icacls.exe "$Path" /grant '*S-1-1-0:(OI)(CI)M' | Out-Null
                $desc = 'Everyone, read and write'
            }
        }
        Done "Shared $Path as \\$env:COMPUTERNAME\$Name ($desc)"
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1
        Info "Reach it from another PC at:  \\$env:COMPUTERNAME\$Name"
        if ($ip) { Info "                           or  \\$($ip.IPAddress)\$Name" }
        Info 'Turning on network discovery so the share is reachable...'
        Enable-NetworkVisibility
    } catch { Fail "Could not create the share: $($_.Exception.Message)" }
}

function Show-Shares {
    Head 'Shared folders on this PC'
    $s = @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.Name -notmatch '\$$' })
    if ($s.Count -eq 0) { Info 'No shared folders (apart from the hidden admin shares).'; return }
    foreach ($x in $s) {
        $acc = @(Get-SmbShareAccess -Name $x.Name -ErrorAction SilentlyContinue | ForEach-Object { "$($_.AccountName)=$($_.AccessRight)" }) -join '; '
        Info ("{0,-20} {1}" -f $x.Name, $x.Path)
        Dim  ("                     access: {0}" -f $acc)
    }
}

function Remove-TqnyShare {
    param([string]$Name)
    Head "Stop sharing $Name"
    try { Remove-SmbShare -Name $Name -Force -ErrorAction Stop; Done "Stopped sharing $Name (the folder and its files were kept)" }
    catch { Fail "No share named $Name, or it could not be removed: $($_.Exception.Message)" }
}

# Password-protected sharing, the switch in Advanced sharing settings.
function Edit-UserRight {
    param([string]$Right, [string]$Sid, [switch]$Remove)
    $d = New-TempDir 'sec'
    try {
        $cur = Join-Path $d 'cur.inf'
        & secedit.exe /export /cfg "$cur" /areas USER_RIGHTS | Out-Null
        $line = Get-Content -LiteralPath $cur -ErrorAction SilentlyContinue | Where-Object { $_ -match "^$Right\s*=" } | Select-Object -First 1
        $vals = @()
        if ($line) { $vals = @((($line -split '=', 2)[1]).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $acct = ''
        try { $acct = (New-Object System.Security.Principal.SecurityIdentifier $Sid).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1] } catch { }
        if ($Remove) { $new = @($vals | Where-Object { $_ -ne "*$Sid" -and $_ -ine $acct }) }
        else { $new = @($vals); if (-not ($vals -contains "*$Sid") -and -not ($acct -and ($vals -contains $acct))) { $new += "*$Sid" } }
        $inf = @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1', '[Privilege Rights]', ("$Right = " + ($new -join ',')))
        $newf = Join-Path $d 'new.inf'
        Set-Content -LiteralPath $newf -Value $inf -Encoding Unicode
        & secedit.exe /configure /db (Join-Path $d 'sec.sdb') /cfg "$newf" /areas USER_RIGHTS /quiet | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

function Set-PasswordSharing {
    param([bool]$On)
    Head ('Password-protected sharing ' + $(if ($On) { 'ON' } else { 'OFF' }))
    $guest = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -match '^S-1-5-21-.*-501$' } | Select-Object -First 1
    if (-not $guest) { Fail 'Could not find the built-in Guest account.'; return }
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $srv = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    try {
        if (-not $On) {
            Enable-LocalUser -SID $guest.SID -ErrorAction Stop
            Set-RegValue $lsa 'everyoneincludesanonymous' 1
            Set-RegValue $srv 'restrictnullsessaccess' 0
            if (Edit-UserRight -Right 'SeDenyNetworkLogonRight' -Sid $guest.SID.Value -Remove) { Ok 'Guest removed from "Deny access to this computer from the network".' }
            Done 'Password-protected sharing turned OFF - shares open without a password'
            Warn 'Anyone on this network can now open shares that allow Everyone. Use only on a trusted office network.'
        } else {
            Disable-LocalUser -SID $guest.SID -ErrorAction Stop
            Set-RegValue $lsa 'everyoneincludesanonymous' 0
            Set-RegValue $srv 'restrictnullsessaccess' 1
            [void](Edit-UserRight -Right 'SeDenyNetworkLogonRight' -Sid $guest.SID.Value)
            Done 'Password-protected sharing turned ON - shares need a user name and password'
        }
    } catch { Fail $_.Exception.Message }
}

function Set-SmbClientCompat {
    param([bool]$On)
    Head ('Open older shares / NAS from this PC: ' + $(if ($On) { 'ALLOW' } else { 'DEFAULT (secure)' }))
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
    $wks = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
    try {
        if ($On) {
            try { Set-SmbClientConfiguration -EnableInsecureGuestLogons $true -RequireSecuritySignature $false -Force -ErrorAction Stop } catch { }
            Set-RegValue $pol 'AllowInsecureGuestAuth' 1
            Set-RegValue $wks 'AllowInsecureGuestAuth' 1
            Set-RegValue $wks 'RequireSecuritySignature' 0
            Done 'Guest access and unsigned SMB allowed for this PC (fixes "cannot access" to NAS / old shares on Windows 11 24H2)'
            Warn 'This lowers SMB security on this PC. Turn it back off when the NAS or share is upgraded.'
        } else {
            try { Set-SmbClientConfiguration -EnableInsecureGuestLogons $false -Force -ErrorAction Stop } catch { }
            Remove-RegValue $pol 'AllowInsecureGuestAuth'
            Set-RegValue $wks 'AllowInsecureGuestAuth' 0
            Remove-RegValue $wks 'RequireSecuritySignature'
            Done 'SMB client back to the secure Windows defaults'
        }
    } catch { Fail $_.Exception.Message }
}

function Set-Smb1 {
    param([bool]$On)
    Head ('SMB1 ' + $(if ($On) { 'ON' } else { 'OFF' }))
    try {
        if ($On) {
            Warn 'SMB1 is old and insecure (WannaCry). Enable it only for an old scanner or NAS that cannot do SMB2.'
            $r = Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -All -NoRestart -ErrorAction Stop
            Done 'SMB1 enabled (needs a restart)'
        } else {
            $r = Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop
            Done 'SMB1 disabled (needs a restart)'
        }
        if ($r.RestartNeeded) { $sync.RebootNeeded = $true }
    } catch { Fail $_.Exception.Message }
}

function Add-SavedCredential {
    param([string]$Server, [string]$User, [string]$Password)
    Head "Save credentials for $Server"
    $Server = $Server.Trim().TrimStart('\')
    if (-not $Server -or -not $User) { Fail 'Type the server name/IP and the user name.'; return }
    $c = Invoke-Native cmdkey.exe @("/add:$Server", "/user:$User", "/pass:$Password") -Quiet
    if ($c -eq 0) { Done "Saved Windows credentials for $Server (user $User)" } else { Fail 'cmdkey could not save the credentials.' }
    Dim 'Saved for the user running this tool. If you started it with a different admin account, save it again there.'
}

function Show-SavedCredentials { Head 'Saved Windows credentials'; Invoke-Native cmdkey.exe @('/list') | Out-Null }

function Remove-SavedCredential {
    param([string]$Server)
    Head "Remove saved credentials for $Server"
    $c = Invoke-Native cmdkey.exe @("/delete:$($Server.Trim().TrimStart('\'))")
    if ($c -eq 0) { Done "Removed saved credentials for $Server" }
}

function Add-MappedDrive {
    param([string]$Letter, [string]$Path, [string]$User, [string]$Password)
    $Letter = $Letter.Trim().TrimEnd(':').ToUpper()
    Head "Map $($Letter): to $Path"
    if ($Letter -notmatch '^[D-Z]$') { Fail 'Use a drive letter from D to Z.'; return }
    if ($Path -notmatch '^\\\\[^\\]+\\.+') { Fail 'The folder must look like \\server\share'; return }
    $a = @("$($Letter):", $Path)
    if ($User) {
        # net use prompts (and would hang here) if a user is given without a password.
        if (-not $Password) { Fail 'Type the password for that user too.'; return }
        $a += @($Password, "/user:$User")
    }
    $a += '/persistent:yes'
    $c = Invoke-Native net.exe (@('use') + $a)
    if ($c -eq 0) {
        Done "Mapped drive $($Letter): to $Path"
        # A drive mapped from an elevated window is invisible to the normal
        # Explorer until linked connections are on (after a restart/sign-in).
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLinkedConnections' 1
        Dim 'Because this tool runs as Administrator, the drive appears in File Explorer after the next sign-in.'
    } else { Fail 'Could not map the drive. Check the path and the credentials.' }
}

function Remove-MappedDrive {
    param([string]$Letter)
    $Letter = $Letter.Trim().TrimEnd(':').ToUpper()
    Head "Disconnect drive $($Letter):"
    $c = Invoke-Native net.exe @('use', "$($Letter):", '/delete', '/y')
    if ($c -eq 0) { Done "Disconnected drive $($Letter):" }
}

# ---- printers and scanners -------------------------------------------------------
function New-Tlv { param([int]$Tag, [byte[]]$Val) return [byte[]](@([byte]$Tag, [byte]$Val.Length) + $Val) }

function Find-Printers {
    param([string]$Base)
    Head 'Find printers and scanners - read only'
    $s = Get-ScanBase $Base
    if (-not $s) { return }
    Info "Looking for printers and scanners on $($s.Base).1-254 ..."
    Set-Progress -1 'Pinging 254 addresses'
    $alive = @((Invoke-PingSweep $s.Base).Keys)
    if ($alive.Count -eq 0) { Info '0 devices answered.'; return }
    Test-Cancel
    Set-Progress -1 'Probing printer ports'
    $portMap = @{ 9100 = 'RAW'; 515 = 'LPD'; 631 = 'IPP' }
    $conns = @()
    foreach ($ip in $alive) {
        foreach ($p in 9100, 515, 631) {
            $c = New-Object System.Net.Sockets.TcpClient
            $conns += [pscustomobject]@{ IP = $ip; Port = $p; Client = $c; Task = $c.ConnectAsync($ip, $p) }
        }
    }
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($conns.Task), 1200) } catch { }
    $proto = @{}
    foreach ($c in $conns) {
        if ($c.Task.Status -eq 'RanToCompletion' -and $c.Client.Connected) {
            if (-not $proto[$c.IP]) { $proto[$c.IP] = New-Object System.Collections.ArrayList }
            [void]$proto[$c.IP].Add($portMap[[int]$c.Port])
        }
        try { $c.Client.Close() } catch { }
    }
    # SNMP GET sysDescr.0 for the model name.
    $oid = [byte[]](0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00)
    $vb = New-Tlv 0x30 ([byte[]]((New-Tlv 0x06 $oid) + (New-Tlv 0x05 ([byte[]]@()))))
    $pdu = New-Tlv 0xA0 ([byte[]]((New-Tlv 0x02 ([byte[]]@(1))) + (New-Tlv 0x02 ([byte[]]@(0))) + (New-Tlv 0x02 ([byte[]]@(0))) + (New-Tlv 0x30 $vb)))
    $pkt = [byte[]](New-Tlv 0x30 ([byte[]]((New-Tlv 0x02 ([byte[]]@(0))) + (New-Tlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes('public'))) + $pdu)))
    $models = @{}
    $targets = @($alive | Where-Object { $proto[$_] })
    if ($targets.Count -gt 0) {
        $us = @(); $rx = @{}
        foreach ($ip in $targets) {
            try {
                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($s.LocalIP), 0)
                $u = New-Object System.Net.Sockets.UdpClient($ep)
                [void]$u.Send($pkt, $pkt.Length, $ip, 161)
                $rx[$ip] = $u.ReceiveAsync(); $us += $u
            } catch { }
        }
        if ($rx.Count -gt 0) {
            try { [void][System.Threading.Tasks.Task]::WaitAll(@($rx.Values), 1500) } catch { }
            foreach ($ip in @($rx.Keys)) {
                $t = $rx[$ip]
                if ($t.Status -ne 'RanToCompletion') { continue }
                $d = $t.Result.Buffer
                for ($i = 0; $i -lt $d.Length - $oid.Length - 2; $i++) {
                    $m = $true
                    for ($j = 0; $j -lt $oid.Length; $j++) { if ($d[$i + $j] -ne $oid[$j]) { $m = $false; break } }
                    if (-not $m) { continue }
                    $vp = $i + $oid.Length
                    if ($d[$vp] -eq 0x04) {
                        $len = $d[$vp + 1]; $st = $vp + 2
                        if ($len -band 0x80) {
                            $nb = $len -band 0x7F; $len = 0
                            for ($x = 0; $x -lt $nb; $x++) { $len = ($len -shl 8) -bor $d[$vp + 2 + $x] }
                            $st = $vp + 2 + $nb
                        }
                        if ($len -gt 0 -and $st + $len -le $d.Length) {
                            $models[$ip] = ([System.Text.Encoding]::ASCII.GetString($d, $st, [Math]::Min($len, 80)) -replace '[\r\n]+', ' ').Trim()
                        }
                    }
                    break
                }
            }
        }
        foreach ($u in $us) { try { $u.Close() } catch { } }
    }
    foreach ($ip in $targets) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://$ip/eSCL/ScannerCapabilities")
            $req.Timeout = 900
            $resp = $req.GetResponse()
            if ([int]$resp.StatusCode -eq 200) { [void]$proto[$ip].Add('eSCL') }
            $resp.Close()
        } catch { }
    }
    $rows = foreach ($ip in ($targets | Sort-Object { [int]($_ -split '\.')[3] })) {
        [pscustomobject]@{
            IP = $ip
            Model = if ($models[$ip]) { $models[$ip] } else { '(model not reported)' }
            Protocols = ($proto[$ip] | Sort-Object -Unique) -join ','
        }
    }
    $rows | Out-Table
    Ok "$(@($rows).Count) printer/scanner device(s) found."
    Dim 'RAW=port 9100  LPD=515  IPP=631 (driverless)  eSCL=network scanning.'
}

function Add-NetPrinter {
    param([string]$Method, [string]$Ip, [string]$Name, [string]$Driver, [string]$Share)
    Head 'Add a printer'
    try {
        switch ($Method) {
            'IPP' {
                if (-not (Test-IPv4 $Ip)) { Fail "'$Ip' is not a valid IP address."; return }
                if (-not $Name) { $Name = "Printer $Ip" }
                Info "Adding $Name over IPP (driverless, Microsoft IPP Class Driver)..."
                $ok = $false
                foreach ($u in @("http://$($Ip):631/ipp/print", "http://$($Ip)/ipp/print", "ipp://$($Ip)/ipp/print")) {
                    try { Add-Printer -Name $Name -IppURL $u -ErrorAction Stop; $ok = $true; Ok "Connected at $u"; break } catch { Dim "  $u : $($_.Exception.Message)" }
                }
                if ($ok) { Done "Added printer $Name (IPP, no driver download)" }
                else { Warn 'Driverless add failed. The printer may not speak IPP. Install its driver and use "TCP/IP + driver".' }
            }
            'TCP' {
                if (-not (Test-IPv4 $Ip)) { Fail "'$Ip' is not a valid IP address."; return }
                if (-not $Driver) { Fail 'Pick or type a driver name.'; return }
                if (-not $Name) { $Name = "Printer $Ip" }
                $port = "IP_$Ip"
                if (-not (Get-PrinterPort -Name $port -ErrorAction SilentlyContinue)) { Add-PrinterPort -Name $port -PrinterHostAddress $Ip -ErrorAction Stop; Ok "Created TCP/IP port $port (RAW 9100)" }
                if (-not (Get-PrinterDriver -Name $Driver -ErrorAction SilentlyContinue)) {
                    Info "Installing driver '$Driver' from the driver store..."
                    Add-PrinterDriver -Name $Driver -ErrorAction Stop
                }
                Add-Printer -Name $Name -DriverName $Driver -PortName $port -ErrorAction Stop
                Done "Added printer $Name on $Ip with driver $Driver"
            }
            'Shared' {
                $Share = $Share.Trim()
                if ($Share -notmatch '^\\\\[^\\]+\\.+') { Fail 'Type the shared printer as \\PC\PrinterShare'; return }
                Add-Printer -ConnectionName $Share -ErrorAction Stop
                Done "Connected shared printer $Share"
            }
        }
    } catch {
        Fail $_.Exception.Message
        if ($Method -eq 'Shared') { Dim 'Error 0x0000011b / 0x00000709 / 0x00000bcb? Use "Fix shared printer errors" on both PCs, then try again.' }
    }
}

function Show-Printers {
    Head 'Installed printers'
    Get-Printer -ErrorAction SilentlyContinue | Out-Table -Property Name, DriverName, PortName, Shared, @{ n = 'Status'; e = { $_.PrinterStatus } }
    $def = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Default } | Select-Object -First 1
    if ($def) { Info "Default printer: $($def.Name)" }
}

function Invoke-TestPrint {
    param([string]$Name)
    Head "Test print to $Name"
    $p = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $p) { Fail "No printer named $Name."; return }
    $r = Invoke-CimMethod -InputObject $p -MethodName PrintTestPage
    if ($r.ReturnValue -eq 0) { Ok "Test page sent to $Name." } else { Fail "The printer refused the test page (code $($r.ReturnValue))." }
}

function Set-DefaultPrinter {
    param([string]$Name)
    Head "Default printer: $Name"
    $p = Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $p) { Fail "No printer named $Name."; return }
    # Stop Windows from moving the default to the last printer used.
    Set-RegValue 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' 'LegacyDefaultPrinterMode' 1
    $r = Invoke-CimMethod -InputObject $p -MethodName SetDefaultPrinter
    if ($r.ReturnValue -eq 0) { Done "Default printer set to $Name" } else { Fail "Could not set the default (code $($r.ReturnValue))." }
}

function Remove-TqnyPrinter {
    param([string]$Name)
    Head "Remove printer $Name"
    try { Remove-Printer -Name $Name -ErrorAction Stop; Done "Removed printer $Name" } catch { Fail $_.Exception.Message }
}

function Set-PrinterSharing {
    param([string]$Name, [string]$ShareName)
    Head "Share printer $Name"
    if (-not $ShareName) { $ShareName = ($Name -replace '[\\/,]', ' ').Trim() }
    try {
        Set-Printer -Name $Name -Shared $true -ShareName $ShareName -ErrorAction Stop
        Done "Shared printer $Name as \\$env:COMPUTERNAME\$ShareName"
        Enable-NetworkVisibility
    } catch { Fail $_.Exception.Message }
}

function Restart-Spooler {
    param([bool]$ClearQueue = $false)
    Head $(if ($ClearQueue) { 'Clear stuck print jobs' } else { 'Restart the print spooler' })
    try {
        Stop-Service -Name Spooler -Force -ErrorAction Stop
        if ($ClearQueue) {
            $q = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
            $n = @(Get-ChildItem -LiteralPath $q -Force -ErrorAction SilentlyContinue).Count
            Get-ChildItem -LiteralPath $q -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Ok "Deleted $n spool file(s)."
        }
        Start-Service -Name Spooler -ErrorAction Stop
        if ($ClearQueue) { Done 'Print queue cleared and spooler restarted' } else { Done 'Print spooler restarted' }
    } catch { Fail $_.Exception.Message }
}

function Repair-SharedPrinting {
    Head 'Fix shared printer errors (0x0000011b / 0x00000709 / 0x00000bcb)'
    try {
        # On the PC that SHARES the printer: allow the older RPC authentication level.
        Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Print' 'RpcAuthnLevelPrivacyEnabled' 0
        # On PCs that CONNECT to it (Windows 11 22H2+): use RPC over named pipes.
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcUseNamedPipeProtocol' 1
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'RpcProtocols' 7
        Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' 'ForceKerberosForRpc' 0
        Done 'Applied the shared-printer compatibility settings'
        Restart-Spooler
        Info 'Run this on BOTH the PC sharing the printer and the PC connecting to it.'
    } catch { Fail $_.Exception.Message }
}

function Install-DriverFolder {
    param([string]$Folder, [string]$What = 'drivers')
    Head "Install $What from $Folder"
    if (-not (Test-Path -LiteralPath $Folder)) { Fail 'That folder does not exist.'; return }
    $n = @(Get-ChildItem -LiteralPath $Folder -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
    if ($n -eq 0) { Fail 'No .inf driver files in that folder. Extract the driver download first.'; return }
    Info "Found $n .inf file(s). Adding them to Windows..."
    $c = Invoke-Native pnputil.exe @('/add-driver', (Join-Path $Folder '*.inf'), '/subdirs', '/install')
    if ($c -eq 0 -or $c -eq 3010 -or $c -eq 259) { Done "Installed $What from $Folder" } else { Warn "pnputil finished with code $c. Some drivers may not match this hardware - that is normal for driver packs." }
    if ($c -eq 3010) { $sync.RebootNeeded = $true }
}

function Install-FaxScan {
    Head 'Install Windows Fax and Scan'
    try {
        $cap = Get-WindowsCapability -Online -Name 'Print.Fax.Scan*' -ErrorAction Stop | Select-Object -First 1
        if (-not $cap) { Fail 'This Windows has no Fax and Scan feature to add.'; return }
        if ($cap.State -eq 'Installed') { Ok 'Windows Fax and Scan is already installed.'; return }
        Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
        Done 'Installed Windows Fax and Scan'
    } catch { Fail $_.Exception.Message }
}


# ---- firewall ------------------------------------------------------------------------
function Show-FirewallStatus {
    Head 'Firewall status'
    Get-NetFirewallProfile -ErrorAction SilentlyContinue | Out-Table -Property Name, Enabled, DefaultInboundAction, DefaultOutboundAction
    $n = @(Get-NetFirewallRule -Group 'TQNY' -ErrorAction SilentlyContinue).Count
    Info "Rules added by this tool (group TQNY): $n"
}

function Set-FirewallState {
    param([string]$Which = 'All', [bool]$On)
    $profiles = if ($Which -eq 'All') { @('Domain', 'Private', 'Public') } else { @($Which) }
    Head ("Firewall {0} for {1}" -f $(if ($On) { 'ON' } else { 'OFF' }), ($profiles -join ', '))
    try {
        Set-NetFirewallProfile -Profile $profiles -Enabled ($(if ($On) { 'True' } else { 'False' })) -ErrorAction Stop
        Done ("Windows Firewall turned {0} for {1}" -f $(if ($On) { 'ON' } else { 'OFF' }), ($profiles -join ', '))
        if (-not $On) { Warn 'The PC is now unprotected on those networks. Turn it back on when you are done.' }
    } catch { Fail $_.Exception.Message }
}

function Set-PingRule {
    param([bool]$Allow)
    Head $(if ($Allow) { 'Allow ping' } else { 'Block ping again' })
    Remove-NetFirewallRule -DisplayName 'TQNY - Allow ping (ICMPv4)' -ErrorAction SilentlyContinue
    if (-not $Allow) { Done 'Removed the TQNY allow-ping rule'; return }
    try {
        New-NetFirewallRule -DisplayName 'TQNY - Allow ping (ICMPv4)' -Group 'TQNY' -Direction Inbound -Protocol ICMPv4 -IcmpType 8 `
            -Action Allow -Profile Domain, Private -ErrorAction Stop | Out-Null
        Done 'Ping (ICMPv4 echo) allowed on Private and Domain networks'
    } catch { Fail $_.Exception.Message }
}

function Add-PortRule {
    param([string]$Name, [string]$Ports, [string]$Proto = 'TCP', [string]$Prof = 'Private')
    Head "Open port $Ports/$Proto"
    $list = @($Ports.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($p in $list) { if ($p -notmatch '^\d{1,5}(-\d{1,5})?$') { Fail "'$p' is not a port or a range like 8000-8100."; return } }
    if (-not $Name) { $Name = "Port $Ports" }
    $pr = if ($Prof -eq 'All') { 'Any' } else { $Prof }
    $protos = if ($Proto -eq 'Both') { @('TCP', 'UDP') } else { @($Proto) }
    try {
        foreach ($x in $protos) {
            New-NetFirewallRule -DisplayName "TQNY - $Name ($x)" -Group 'TQNY' -Direction Inbound -Protocol $x -LocalPort $list -Action Allow -Profile $pr -ErrorAction Stop | Out-Null
            Done "Firewall: opened inbound $x $Ports ($Name) on $pr"
        }
    } catch { Fail $_.Exception.Message }
}

function Add-ProgramRule {
    param([string]$Path)
    Head "Allow a program through the firewall"
    if (-not (Test-Path -LiteralPath $Path)) { Fail "File not found: $Path"; return }
    $n = [IO.Path]::GetFileNameWithoutExtension($Path)
    try {
        New-NetFirewallRule -DisplayName "TQNY - $n" -Group 'TQNY' -Direction Inbound -Program $Path -Action Allow -Profile Domain, Private -ErrorAction Stop | Out-Null
        Done "Firewall: allowed $n inbound on Private and Domain networks"
    } catch { Fail $_.Exception.Message }
}

function Show-TqnyRules {
    Head 'Firewall rules added by TQNY-Setup'
    Get-NetFirewallRule -Group 'TQNY' -ErrorAction SilentlyContinue | Out-Table -Property DisplayName, Enabled, Direction, Action, Profile
}

function Remove-TqnyRules {
    Head 'Remove all TQNY firewall rules'
    $n = @(Get-NetFirewallRule -Group 'TQNY' -ErrorAction SilentlyContinue).Count
    Remove-NetFirewallRule -Group 'TQNY' -ErrorAction SilentlyContinue
    Done "Removed $n firewall rule(s) added by TQNY-Setup"
}

function Reset-Firewall {
    Head 'Reset the firewall to Windows defaults'
    $c = Invoke-Native netsh.exe @('advfirewall', 'reset')
    if ($c -eq 0) { Done 'Windows Firewall reset to its default rules'; Warn 'Custom rules, including Network Discovery, were reset. Run "Make this PC visible" again if needed.' }
    else { Fail 'netsh could not reset the firewall.' }
}

# ---- Windows Defender ------------------------------------------------------------------
function Show-DefenderStatus {
    Head 'Windows Defender'
    try {
        $m = Get-MpComputerStatus -ErrorAction Stop
        Info "Real-time protection : $($m.RealTimeProtectionEnabled)"
        Info "Tamper Protection    : $($m.IsTamperProtected)"
        Info "Antivirus signatures : $($m.AntivirusSignatureVersion)  ($($m.AntivirusSignatureLastUpdated))"
        Info "Last quick scan      : $($m.QuickScanEndTime)"
        Info "Last full scan       : $($m.FullScanEndTime)"
    } catch { Warn 'Defender is not answering. Another antivirus is probably installed and in charge.' }
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
    foreach ($a in $av) { Info "Antivirus registered : $($a.displayName)" }
}

function Set-DefenderRealtime {
    param([bool]$On)
    Head ('Defender real-time protection ' + $(if ($On) { 'ON' } else { 'OFF' }))
    try {
        $m = Get-MpComputerStatus -ErrorAction Stop
        if (-not $On -and $m.IsTamperProtected) {
            Warn 'Tamper Protection is ON. Windows will block or revert this. Turn Tamper Protection off in Windows Security first.'
        }
        Set-MpPreference -DisableRealtimeMonitoring (-not $On) -ErrorAction Stop
        Start-Sleep -Seconds 1
        $now = (Get-MpComputerStatus).RealTimeProtectionEnabled
        Info "Real-time protection is now: $now"
        if ($now -eq $On) { Done ('Defender real-time protection turned ' + $(if ($On) { 'ON' } else { 'OFF' })) }
        elseif (-not $On) { Warn 'As warned, Tamper Protection reverted it. Turn that off first.' }
    } catch { Fail $_.Exception.Message }
}

function Invoke-DefenderTask {
    param([string]$Task, [string]$Path)
    try {
        switch ($Task) {
            'quick'  { Head 'Defender quick scan'; Info 'Scanning, usually 2-10 minutes...'; Start-MpScan -ScanType QuickScan -ErrorAction Stop; Done 'Defender quick scan completed' }
            'full'   { Head 'Defender full scan'; Info 'Scanning every file. This can take an hour or more...'; Start-MpScan -ScanType FullScan -ErrorAction Stop; Done 'Defender full scan completed' }
            'update' { Head 'Update Defender signatures'; Update-MpSignature -ErrorAction Stop; Done "Defender signatures updated to $((Get-MpComputerStatus).AntivirusSignatureVersion)" }
            'exclude' {
                Head "Add Defender exclusion"
                if (-not (Test-Path -LiteralPath $Path)) { Fail "Folder not found: $Path"; return }
                Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
                Done "Defender will no longer scan $Path"
            }
        }
        if ($Task -in 'quick', 'full') {
            $t = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-3) })
            if ($t.Count) { Warn "$($t.Count) threat(s) detected recently. Open Windows Security > Protection history." } else { Ok 'No threats found.' }
        }
    } catch { Fail $_.Exception.Message }
}

# ---- BitLocker -----------------------------------------------------------------------
function Show-BitLocker {
    param([bool]$Keys = $false)
    Head $(if ($Keys) { 'BitLocker recovery keys' } else { 'BitLocker status' })
    if ($Keys) {
        Warn 'Write these down BEFORE formatting or changing the motherboard. Without the key the data is gone.'
        foreach ($v in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            Invoke-Native manage-bde.exe @('-protectors', '-get', $v.DeviceID) | Out-Null
        }
    } else {
        Invoke-Native manage-bde.exe @('-status') | Out-Null
    }
}

function Set-BitLockerAction {
    param([string]$Action)
    $drv = $env:SystemDrive
    try {
        switch ($Action) {
            'suspend' {
                Head "Suspend BitLocker on $drv for one restart"
                $c = Invoke-Native manage-bde.exe @('-protectors', '-disable', $drv, '-RebootCount', '1')
                if ($c -eq 0) { Done "BitLocker suspended on $drv until the next restart (for BIOS updates / hardware changes)" } else { Fail 'Could not suspend BitLocker.' }
            }
            'off' {
                Head "Turn off BitLocker on $drv (decrypt)"
                $c = Invoke-Native manage-bde.exe @('-off', $drv)
                if ($c -eq 0) { Done "BitLocker decryption started on $drv - it continues in the background" } else { Fail 'Could not turn BitLocker off.' }
            }
        }
    } catch { Fail $_.Exception.Message }
}

# ---- activation (genuine keys only) --------------------------------------------------
function Get-Slmgr { Join-Path $env:SystemRoot 'System32\slmgr.vbs' }

function Show-WindowsActivation {
    Head 'Windows activation'
    Invoke-Native cscript.exe @('//nologo', (Get-Slmgr), '/dli') | Out-Null
    Invoke-Native cscript.exe @('//nologo', (Get-Slmgr), '/xpr') | Out-Null
}

function Show-OemKey {
    Head 'Product key stored in the BIOS (OEM)'
    $k = [string](Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue).OA3xOriginalProductKey
    if ($k) { Ok "OEM key: $k"; Info "Edition it is for: $((Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKeyDescription)" }
    else { Info 'No key in the BIOS. This PC was not sold with a factory Windows licence, or it uses a digital licence.' }
    return $k
}

function Install-WindowsKey {
    param([string]$Key)
    Head 'Activate Windows'
    $Key = $Key.Trim().ToUpper()
    if ($Key -eq 'OEM') { $Key = [string](Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey; if (-not $Key) { Fail 'There is no OEM key in this BIOS.'; return } }
    if ($Key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { Fail 'A product key looks like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.'; return }
    Info 'Installing the product key...'
    $c = Invoke-Native cscript.exe @('//nologo', (Get-Slmgr), '/ipk', $Key)
    if ($c -ne 0) { Fail 'Windows rejected the key. Check it matches this edition (Home / Pro).'; return }
    Info 'Activating online...'
    $c = Invoke-Native cscript.exe @('//nologo', (Get-Slmgr), '/ato')
    if ($c -eq 0) { Done ('Windows activated with key ending ' + $Key.Substring($Key.Length - 5)) }
    else { Fail 'Activation failed. Check the internet, or use Settings > Activation > Troubleshoot.' }
}

function Find-Ospp {
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $b) { continue }
        foreach ($v in 'Office16', 'Office15') {
            $p = Join-Path $b "Microsoft Office\$v\OSPP.VBS"
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

function Show-OfficeActivation {
    Head 'Office activation'
    $o = Find-Ospp
    if (-not $o) { Info 'No volume / retail Office (OSPP.VBS) found. Microsoft 365 activates by signing in to an Office app.'; return }
    Invoke-Native cscript.exe @('//nologo', $o, '/dstatus') | Out-Null
}

function Install-OfficeKey {
    param([string]$Key)
    Head 'Activate Office'
    $o = Find-Ospp
    if (-not $o) { Fail 'No Office with OSPP.VBS found. Microsoft 365: open Word and sign in with the licensed account.'; return }
    $Key = $Key.Trim().ToUpper()
    if ($Key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { Fail 'A product key looks like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX.'; return }
    $c = Invoke-Native cscript.exe @('//nologo', $o, "/inpkey:$Key")
    if ($c -ne 0) { Fail 'Office rejected the key.'; return }
    $c = Invoke-Native cscript.exe @('//nologo', $o, '/act')
    if ($c -eq 0) { Done ('Office activated with key ending ' + $Key.Substring($Key.Length - 5)) } else { Warn 'Key installed; check the activation lines above.' }
}

# ---- PC setup ----------------------------------------------------------------------------
function Set-TimeZoneSync {
    param([string]$TzId)
    Head 'Time zone and clock'
    Info "Current time zone : $((Get-TimeZone).Id)"
    try { Set-TimeZone -Id $TzId -ErrorAction Stop; Done "Time zone set to $TzId" } catch { Fail "Could not set the time zone: $($_.Exception.Message)" }
    try { Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service w32time -ErrorAction SilentlyContinue } catch { }
    $c = Invoke-Native w32tm.exe @('/resync', '/force') -Quiet
    if ($c -eq 0) { Done 'Clock synchronised with the internet time server' } else { Warn 'Clock resync did not complete. Check the internet connection.' }
    Info "Time now: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}

function Set-PowerPlan {
    param([string[]]$What)
    Head 'Power settings'
    if ($What -contains 'never') {
        foreach ($a in @(@('standby-timeout-ac', '0'), @('hibernate-timeout-ac', '0'), @('monitor-timeout-ac', '15'), @('disk-timeout-ac', '0'))) {
            Invoke-Native powercfg.exe @('/change', $a[0], $a[1]) -Quiet | Out-Null
        }
        Done 'Power: never sleep on mains power, screen off after 15 minutes'
    }
    if ($What -contains 'high') {
        $c = Invoke-Native powercfg.exe @('/setactive', 'SCHEME_MIN') -Quiet
        if ($c -eq 0) { Done 'Power plan set to High performance' } else { Warn 'High performance plan is not available on this PC (common on Modern Standby laptops).' }
    }
    if ($What -contains 'hiberoff') {
        $c = Invoke-Native powercfg.exe @('/hibernate', 'off') -Quiet
        if ($c -eq 0) { Done 'Hibernation turned off (frees disk space; also disables Fast Startup)' }
    }
    if ($What -contains 'lid') {
        Invoke-Native powercfg.exe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0') -Quiet | Out-Null
        Invoke-Native powercfg.exe @('/setactive', 'SCHEME_CURRENT') -Quiet | Out-Null
        Done 'Closing the laptop lid on mains power does nothing'
    }
    if ($What -contains 'faststartup') {
        try { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0; Done 'Fast Startup turned off (fixes shares, Wake-on-LAN and dual-boot issues)' }
        catch { Fail $_.Exception.Message }
    }
}

function Set-ComputerDescription {
    param([string]$Text)
    Head 'Computer description'
    try { Set-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'srvcomment' $Text 'String'; Done "Computer description set to: $Text" }
    catch { Fail $_.Exception.Message }
}

function Set-Workgroup {
    param([string]$Name)
    Head "Join workgroup $Name"
    if ($Facts.InDomain) { Fail 'This PC is in a domain. Leave the domain first (System Properties).'; return }
    try { Add-Computer -WorkgroupName $Name -ErrorAction Stop -WarningAction SilentlyContinue; Done "Workgroup set to $Name (active after a restart)"; $sync.RebootNeeded = $true }
    catch { Fail $_.Exception.Message }
}

function Join-TqnyDomain {
    param([string]$Domain, [pscredential]$Cred, [string]$OU)
    Head "Join domain $Domain"
    try {
        if ($OU) { Add-Computer -DomainName $Domain -Credential $Cred -OUPath $OU -Force -ErrorAction Stop -WarningAction SilentlyContinue }
        else { Add-Computer -DomainName $Domain -Credential $Cred -Force -ErrorAction Stop -WarningAction SilentlyContinue }
        Done "Joined domain $Domain (active after a restart)"; $sync.RebootNeeded = $true
    } catch { Fail $_.Exception.Message }
}

function Set-ExplorerTweaks {
    param([string[]]$What)
    Head 'Explorer and desktop'
    $adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    try {
        if ($What -contains 'ext')    { Set-RegValue $adv 'HideFileExt' 0; Done 'File extensions shown (.pdf, .exe, ...)' }
        if ($What -contains 'hidden') { Set-RegValue $adv 'Hidden' 1; Done 'Hidden files shown' }
        if ($What -contains 'thispc') { Set-RegValue $adv 'LaunchTo' 1; Done 'File Explorer opens to This PC' }
        if ($What -contains 'icons') {
            $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel'
            foreach ($g in '{20D04FE0-3AEA-1069-A2D8-08002B30309D}', '{59031a47-3f72-44a7-89c5-5595fe6b30ee}', '{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}', '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}', '{645FF040-5081-101B-9F08-00AA002F954E}') {
                Set-RegValue $k $g 0
            }
            Done 'Desktop icons shown: This PC, user folder, Network, Control Panel, Recycle Bin'
        }
        if ($What -contains 'classicmenu') {
            Set-RegValue 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' 'String'
            Done 'Windows 11: full right-click menu restored'
        }
        if ($What -contains 'taskleft') { Set-RegValue $adv 'TaskbarAl' 0; Done 'Windows 11: taskbar aligned left' }
        if ($What -contains 'searchicon') { Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1; Done 'Taskbar search shown as an icon' }
        Restart-Explorer
        Dim 'These apply to the user running this tool. Start it from the customer account to set them there.'
    } catch { Fail $_.Exception.Message }
}

function Add-ArabicKeyboard {
    Head 'Arabic keyboard'
    try {
        $l = Get-WinUserLanguageList
        if ($l | Where-Object { $_.LanguageTag -like 'ar*' }) { Ok 'An Arabic keyboard is already installed.' }
        else { $l.Add('ar-SA'); Set-WinUserLanguageList $l -Force -ErrorAction Stop; Done 'Arabic (Saudi Arabia) keyboard added - switch with Win+Space or Alt+Shift' }
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            try { Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true -ErrorAction Stop; Ok 'Copied to the sign-in screen and new users.' } catch { }
        }
    } catch { Fail $_.Exception.Message }
}

function Set-RegionFormat {
    param([string]$Culture)
    Head "Regional format $Culture"
    try { Set-Culture -CultureInfo $Culture -ErrorAction Stop; Done "Date, time and number format set to $Culture" } catch { Fail $_.Exception.Message }
}

function Enable-NetFx3 {
    Head 'Enable .NET Framework 3.5'
    Info 'Downloads from Windows Update, usually 2-5 minutes...'
    $c = Invoke-Native dism.exe @('/Online', '/Enable-Feature', '/FeatureName:NetFx3', '/All', '/NoRestart')
    if ($c -eq 0 -or $c -eq 3010) { Done '.NET Framework 3.5 enabled (for older apps)' } else { Fail "DISM finished with code $c. Needs internet / Windows Update working." }
}

function New-TqnyRestorePoint {
    param([string]$Description = 'TQNY-Setup')
    Head 'Create a restore point'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows allows one restore point per 24 h unless this is 0.
        Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        Done "Restore point created: $Description"
    } catch { Fail "Could not create a restore point: $($_.Exception.Message)" }
}

# ---- local users -------------------------------------------------------------------------
function Show-LocalUsers {
    Head 'Local user accounts'
    $adm = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Split('\')[-1] })
    Get-LocalUser -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Enabled = $_.Enabled; Admin = ($adm -contains $_.Name); PasswordRequired = $_.PasswordRequired; LastLogon = $_.LastLogon }
    } | Out-Table
}

function New-TqnyUser {
    param([string]$User, [string]$Password, [bool]$Admin)
    Head "Create user $User"
    if ($User -notmatch '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') { Fail 'User names are up to 20 characters, without \ / [ ] : ; | = , + * ? < > " @'; return }
    try {
        if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) { Fail "User $User already exists."; return }
        if ($Password) { New-LocalUser -Name $User -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -PasswordNeverExpires -ErrorAction Stop | Out-Null }
        else { New-LocalUser -Name $User -NoPassword -ErrorAction Stop | Out-Null }
        Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $User -ErrorAction SilentlyContinue
        if ($Admin) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $User -ErrorAction Stop }
        Done ("Created local user $User" + $(if ($Admin) { ' (Administrator)' } else { ' (standard user)' }))
    } catch { Fail $_.Exception.Message }
}

function Set-TqnyUserPassword {
    param([string]$User, [string]$Password)
    Head "Set password for $User"
    try {
        if ($Password) { Set-LocalUser -Name $User -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop }
        else { Set-LocalUser -Name $User -Password (New-Object System.Security.SecureString) -ErrorAction Stop }
        Done "Password changed for $User"
    } catch { Fail $_.Exception.Message }
}

function Set-UserAdmin {
    param([string]$User, [bool]$Admin)
    Head ("{0} {1} {2} Administrators" -f $(if ($Admin) { 'Add' } else { 'Remove' }), $User, $(if ($Admin) { 'to' } else { 'from' }))
    try {
        if ($Admin) { Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $User -ErrorAction Stop; Done "$User is now an Administrator" }
        else { Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $User -ErrorAction Stop; Done "$User is now a standard user" }
    } catch { Fail $_.Exception.Message }
}

function Set-BuiltinAdmin {
    param([bool]$On, [string]$Password)
    Head ('Built-in Administrator account ' + $(if ($On) { 'ON' } else { 'OFF' }))
    $a = Get-LocalUser -ErrorAction SilentlyContinue | Where-Object { $_.SID.Value -match '^S-1-5-21-.*-500$' } | Select-Object -First 1
    if (-not $a) { Fail 'Built-in Administrator not found.'; return }
    try {
        if ($On) {
            if ($Password) { Set-LocalUser -SID $a.SID -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop }
            Enable-LocalUser -SID $a.SID -ErrorAction Stop
            Done "Built-in Administrator ($($a.Name)) enabled"
            if (-not $Password) { Warn 'It has no password set by this tool. Set one with "Set password".' }
        } else { Disable-LocalUser -SID $a.SID -ErrorAction Stop; Done "Built-in Administrator ($($a.Name)) disabled" }
    } catch { Fail $_.Exception.Message }
}

# ---- drivers -------------------------------------------------------------------------------
function Show-ProblemDevices {
    Head 'Devices with problems (missing or failed drivers)'
    $d = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($d.Count -eq 0) { Ok 'Every device has a working driver.'; return }
    $d | Out-Table -Property @{ n = 'Device'; e = { if ($_.Name) { $_.Name } else { '(unknown device)' } } }, @{ n = 'Code'; e = { $_.ConfigManagerErrorCode } }, @{ n = 'Hardware ID'; e = { @($_.HardwareID)[0] } }
    Warn "$($d.Count) device(s) need attention. Code 28 = no driver installed, 10 = cannot start, 22 = disabled."
    Info 'Try "Drivers from Windows Update" first, then the manufacturer support page.'
}

function Show-ThirdPartyDrivers {
    Head 'Installed third-party drivers'
    Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DriverProviderName -and $_.DriverProviderName -notmatch '^Microsoft' -and $_.DeviceName } |
        Sort-Object DeviceClass, DeviceName |
        Out-Table -Property @{ n = 'Class'; e = { $_.DeviceClass } }, @{ n = 'Device'; e = { $_.DeviceName } }, @{ n = 'Provider'; e = { $_.DriverProviderName } }, @{ n = 'Version'; e = { $_.DriverVersion } }
}

function Export-Drivers {
    param([string]$Folder)
    Head "Back up drivers to $Folder"
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    Info 'Exporting every third-party driver package. A minute or two...'
    $c = Invoke-Native pnputil.exe @('/export-driver', '*', $Folder) -Quiet
    $n = @(Get-ChildItem -LiteralPath $Folder -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count
    if ($c -eq 0 -or $n -gt 0) { Done "Backed up $n driver package(s)" } else { Fail "pnputil finished with code $c." }
}

function Invoke-HardwareRescan {
    Head 'Scan for hardware changes'
    $c = Invoke-Native pnputil.exe @('/scan-devices')
    if ($c -eq 0) { Ok 'Windows rescanned the hardware.' }
}

# ---- Windows Update (built-in Windows Update Agent, no module needed) --------------------------
function Get-WuSession { $s = New-Object -ComObject Microsoft.Update.Session; $s.ClientApplicationID = 'TQNY-Setup'; return $s }

function Find-WindowsUpdates {
    param([string]$Kind = 'Software', [bool]$MicrosoftUpdate = $false)
    $s = Get-WuSession
    $searcher = $s.CreateUpdateSearcher()
    if ($MicrosoftUpdate) {
        try {
            $sm = New-Object -ComObject Microsoft.Update.ServiceManager
            [void]$sm.AddService2('7971f918-a847-4430-9279-4a52d1efd18d', 7, '')
            $searcher.ServerSelection = 3
            $searcher.ServiceID = '7971f918-a847-4430-9279-4a52d1efd18d'
            Ok 'Microsoft Update enabled (also updates Office and other Microsoft products).'
        } catch { Warn 'Could not enable Microsoft Update; checking Windows Update only.' }
    }
    $crit = switch ($Kind) { 'Driver' { "IsInstalled=0 and IsHidden=0 and Type='Driver'" } 'All' { 'IsInstalled=0 and IsHidden=0' } default { "IsInstalled=0 and IsHidden=0 and Type='Software'" } }
    Info 'Searching for updates. This can take a few minutes on a fresh install...'
    Set-Progress -1 'Searching for updates'
    $r = $searcher.Search($crit)
    return @{ Session = $s; Updates = $r.Updates }
}

function Show-WindowsUpdates {
    param([string]$Kind = 'All', [bool]$MicrosoftUpdate = $false)
    Head 'Check for updates'
    try {
        $x = Find-WindowsUpdates -Kind $Kind -MicrosoftUpdate $MicrosoftUpdate
        $list = for ($i = 0; $i -lt $x.Updates.Count; $i++) {
            $u = $x.Updates.Item($i)
            [pscustomobject]@{ Type = $(if ($u.Type -eq 2) { 'Driver' } else { 'Update' }); 'Size MB' = [math]::Round($u.MaxDownloadSize / 1MB); Title = $u.Title }
        }
        if (-not $list) { Ok 'This PC is up to date.'; return }
        $list | Out-Table
        Info "$(@($list).Count) update(s) available. Use 'Install all updates' to install them."
    } catch { Fail "Windows Update search failed: $($_.Exception.Message)" }
}

function Install-WindowsUpdates {
    param([string]$Kind = 'Software', [bool]$MicrosoftUpdate = $false)
    Head $(if ($Kind -eq 'Driver') { 'Install drivers from Windows Update' } else { 'Install Windows updates' })
    try {
        $x = Find-WindowsUpdates -Kind $Kind -MicrosoftUpdate $MicrosoftUpdate
        $n = $x.Updates.Count
        if ($n -eq 0) { Ok 'Nothing to install. This PC is up to date.'; return }
        Info "$n update(s) to install. Each one downloads, then installs."
        $okCount = 0; $failCount = 0
        for ($i = 0; $i -lt $n; $i++) {
            Test-Cancel
            $u = $x.Updates.Item($i)
            Set-Progress ([math]::Round(100 * $i / $n)) ("Update {0}/{1}: {2}" -f ($i + 1), $n, $u.Title)
            Log ''
            Log ("  [{0}/{1}] {2}" -f ($i + 1), $n, $u.Title) 'info'
            if ($u.InstallationBehavior.CanRequestUserInput) { Warn 'Skipped - this update needs someone to click through it. Install it from Settings.'; continue }
            if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch { } }
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$coll.Add($u)
            if (-not $u.IsDownloaded) {
                $dl = $x.Session.CreateUpdateDownloader(); $dl.Updates = $coll
                $dr = $dl.Download()
                if ($dr.ResultCode -ne 2 -and $dr.ResultCode -ne 3) { Fail "Download failed (result $($dr.ResultCode))."; $failCount++; continue }
            }
            $inst = $x.Session.CreateUpdateInstaller(); $inst.Updates = $coll
            $ir = $inst.Install()
            if ($ir.ResultCode -eq 2 -or $ir.ResultCode -eq 3) {
                $okCount++
                Done ("Installed update: " + $u.Title)
                if ($ir.RebootRequired) { $sync.RebootNeeded = $true }
            } else { $failCount++; Fail ("Install failed (result {0}, HRESULT 0x{1:X8})." -f $ir.ResultCode, $ir.HResult) }
        }
        Set-Progress 100
        Log ''
        Ok "$okCount installed, $failCount failed, of $n."
        if ($sync.RebootNeeded) { Warn 'A restart is needed to finish installing. Then run this again - Windows often offers more updates after a restart.' }
    } catch {
        if ("$_" -eq 'TQNY_CANCELLED') { throw }
        Fail "Windows Update failed: $($_.Exception.Message)"
        Info 'If this keeps failing, use Repair > "Reset Windows Update" and try again.'
    }
}

function Show-UpdateHistory {
    Head 'Update history (last 30)'
    try {
        $s = Get-WuSession; $q = $s.CreateUpdateSearcher()
        $total = $q.GetTotalHistoryCount()
        if ($total -eq 0) { Info 'No update history yet.'; return }
        $h = $q.QueryHistory(0, [Math]::Min(30, $total))
        $rows = foreach ($e in $h) {
            if (-not $e.Title) { continue }
            [pscustomobject]@{ Date = $e.Date.ToLocalTime().ToString('yyyy-MM-dd'); Result = switch ($e.ResultCode) { 2 { 'OK' } 3 { 'OK*' } 4 { 'FAILED' } 5 { 'Aborted' } default { 'Pending' } }; Title = $e.Title }
        }
        $rows | Out-Table
    } catch { Fail $_.Exception.Message }
}

function Set-WindowsUpdateMode {
    param([string]$Mode)
    $ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    try {
        switch ($Mode) {
            'on' {
                Head 'Windows Update ON'
                Set-Service wuauserv -StartupType Manual -ErrorAction Stop
                Start-Service wuauserv -ErrorAction SilentlyContinue
                foreach ($v in 'PauseUpdatesStartTime', 'PauseUpdatesExpiryTime', 'PauseFeatureUpdatesStartTime', 'PauseFeatureUpdatesEndTime', 'PauseQualityUpdatesStartTime', 'PauseQualityUpdatesEndTime') { Remove-RegValue $ux $v }
                Done 'Windows Update service enabled and any pause removed'
            }
            'off' {
                Head 'Windows Update OFF'
                Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
                Set-Service wuauserv -StartupType Disabled -ErrorAction Stop
                Done 'Windows Update service stopped and disabled'
                Warn 'Windows often re-enables Update on its own. Pausing is more reliable.'
            }
            'pause' {
                Head 'Pause updates for 7 days'
                $st = (Get-Date).ToUniversalTime(); $en = $st.AddDays(7)
                $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
                Set-RegValue $ux 'PauseUpdatesStartTime' $st.ToString($fmt) 'String'
                Set-RegValue $ux 'PauseUpdatesExpiryTime' $en.ToString($fmt) 'String'
                Set-RegValue $ux 'PauseFeatureUpdatesStartTime' $st.ToString($fmt) 'String'
                Set-RegValue $ux 'PauseFeatureUpdatesEndTime' $en.ToString($fmt) 'String'
                Set-RegValue $ux 'PauseQualityUpdatesStartTime' $st.ToString($fmt) 'String'
                Set-RegValue $ux 'PauseQualityUpdatesEndTime' $en.ToString($fmt) 'String'
                Done "Windows updates paused until $($en.ToLocalTime().ToString('yyyy-MM-dd'))"
            }
        }
        $s = Get-Service wuauserv
        Info "Update service: $($s.Status), start type $($s.StartType)"
    } catch { Fail $_.Exception.Message }
}

function Reset-WindowsUpdate {
    Head 'Reset Windows Update components'
    $svcs = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    foreach ($s in $svcs) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    $stamp = Get-Stamp
    foreach ($d in @((Join-Path $env:SystemRoot 'SoftwareDistribution'), (Join-Path $env:SystemRoot 'System32\catroot2'))) {
        if (Test-Path -LiteralPath $d) {
            try { Rename-Item -LiteralPath $d -NewName ((Split-Path $d -Leaf) + ".old-$stamp") -ErrorAction Stop; Ok "Renamed $d" }
            catch { Warn "Could not rename $d ($($_.Exception.Message))" }
        }
    }
    foreach ($s in $svcs) { Start-Service -Name $s -ErrorAction SilentlyContinue }
    Done 'Windows Update components reset - Windows rebuilds its update cache'
    Info 'Check for updates again now. The .old folders can be deleted later with Cleanup.'
}

# ---- apps (winget) ------------------------------------------------------------------------
function Get-WingetPath {
    $c = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    $d = Get-ChildItem (Join-Path $env:ProgramFiles 'WindowsApps') -Directory -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
         Sort-Object { try { [version](($_.Name -split '_')[1]) } catch { [version]'0.0' } } -Descending | Select-Object -First 1
    if ($d -and (Test-Path -LiteralPath (Join-Path $d.FullName 'winget.exe'))) { return (Join-Path $d.FullName 'winget.exe') }
    return $null
}

function Get-WingetVersion {
    $w = Get-WingetPath
    if (-not $w) { return $null }
    $t = Get-NativeText $w @('--version')
    if ($t -match 'v?(\d+\.\d+(\.\d+)?)') { try { return [version]$matches[1] } catch { } }
    return $null
}

function Install-Winget {
    Head 'Install / repair winget (App Installer)'
    $v = Get-WingetVersion
    if ($v) { Info "winget $v is present. Repairing / updating it anyway." }
    $done = $false
    try {
        Info 'Method 1: Microsoft.WinGet.Client from the PowerShell Gallery...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null
        Install-Module -Name Microsoft.WinGet.Client -Force -Scope AllUsers -AllowClobber -Repository PSGallery -ErrorAction Stop -WarningAction SilentlyContinue
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop | Out-Null
        $done = $true
    } catch { Warn "Method 1 failed: $($_.Exception.Message)" }
    if (-not $done) {
        Info 'Method 2: direct download of App Installer and its dependencies...'
        $d = New-TempDir 'winget'
        try {
            $parts = @(
                @('https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx', 'vclibs.appx'),
                @('https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx', 'uixaml.appx'),
                @('https://aka.ms/getwinget', 'winget.msixbundle'))
            foreach ($p in $parts) {
                $f = Join-Path $d $p[1]
                Info "Downloading $($p[1])..."
                if (-not (Get-WebFile $p[0] $f)) { continue }
                try { Add-AppxPackage -Path $f -ErrorAction Stop; Ok "Installed $($p[1])" } catch { Warn "$($p[1]): $($_.Exception.Message)" }
            }
            $done = [bool](Get-WingetPath)
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $v = Get-WingetVersion
    if ($v) { Done "winget $v ready" } else { Fail 'winget is still not available. Open Microsoft Store > Library > update "App Installer", then try again.' }
}

function Get-WingetBaseArgs {
    $a = @('--accept-package-agreements', '--accept-source-agreements')
    $v = Get-WingetVersion
    if ($v -and $v -ge [version]'1.4') { $a += '--disable-interactivity' }
    return $a
}

function Install-WingetApps {
    param([object[]]$Apps)
    Head 'Install apps'
    $wg = Get-WingetPath
    if (-not $wg) { Fail 'winget is not available on this PC. Use "Install / repair winget" first.'; return }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $base = Get-WingetBaseArgs
    $n = @($Apps).Count
    $i = 0; $okList = @(); $bad = @()
    foreach ($a in $Apps) {
        Test-Cancel
        Set-Progress ([math]::Round(100 * $i / [math]::Max($n, 1))) ("Installing {0}/{1}: {2}" -f ($i + 1), $n, $a.Name)
        $i++
        Log ''
        Log ("  [{0}/{1}] {2}" -f $i, $n, $a.Name) 'info'
        $allOk = $true
        foreach ($id in ([string]$a.Id).Split(',')) {
            $id = $id.Trim(); if (-not $id) { continue }
            $args1 = @('install', '--id', $id, '--exact', '--silent') + $base
            if ($a.Src) { $args1 += @('--source', $a.Src) }
            $c = Invoke-Native $wg $args1
            if ($c -eq 0) { }
            elseif ($c -eq -1978335189 -or $c -eq -1978335135) { Dim "$id is already installed and up to date." }
            else { $allOk = $false; Fail ("{0}: winget exit code 0x{1:X8}" -f $id, $c) }
        }
        if ($allOk) { $okList += $a.Name; Done "Installed $($a.Name)"; [void]$sync.Apps.Add($a.Name) } else { $bad += $a.Name }
    }
    Set-Progress 100
    Log ''
    Ok "$($okList.Count) of $n app(s) installed or already present."
    if ($bad.Count) { Warn ("Failed: " + ($bad -join ', ') + '. Try them again, or install by hand.') }
}

function Invoke-WingetCommand {
    param([string]$What, [string]$Arg)
    $wg = Get-WingetPath
    if (-not $wg) { Fail 'winget is not available on this PC. Use "Install / repair winget" first.'; return }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $base = Get-WingetBaseArgs
    switch ($What) {
        'upgrade' {
            Head 'Update every installed app'
            Info 'winget updates everything it knows about. This can take a while...'
            $c = Invoke-Native $wg (@('upgrade', '--all', '--silent', '--include-unknown') + $base)
            if ($c -eq 0) { Done 'Updated all installed apps (winget upgrade --all)' } else { Warn "winget finished with code $c - some apps may need updating by hand." }
        }
        'list-upgrades' { Head 'Apps with updates available'; Invoke-Native $wg @('upgrade', '--include-unknown', '--accept-source-agreements') | Out-Null }
        'search' { Head "Search winget for '$Arg'"; Invoke-Native $wg @('search', $Arg, '--accept-source-agreements') | Out-Null; Info 'Copy the Id into "Install by ID".' }
        'export' {
            Head "Export app list to $Arg"
            $c = Invoke-Native $wg @('export', '-o', $Arg, '--accept-source-agreements')
            if (Test-Path -LiteralPath $Arg) { Ok "App list saved: $Arg" } else { Fail "winget export failed ($c)." }
        }
        'import' {
            Head "Install apps from list $Arg"
            $c = Invoke-Native $wg (@('import', '-i', $Arg, '--ignore-unavailable', '--ignore-versions') + @('--accept-package-agreements', '--accept-source-agreements'))
            if ($c -eq 0) { Done "Installed apps from the list $(Split-Path $Arg -Leaf)" } else { Warn "winget import finished with code $c - check the lines above." }
        }
    }
}

function Get-InstalledPrograms {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
        Select-Object @{ n = 'Name'; e = { $_.DisplayName } }, @{ n = 'Version'; e = { $_.DisplayVersion } }, Publisher, InstallDate |
        Sort-Object Name -Unique
}

function Export-InstalledPrograms {
    param([string]$File)
    Head 'Installed programs'
    $p = @(Get-InstalledPrograms)
    $p | Export-Csv -LiteralPath $File -NoTypeInformation -Encoding UTF8
    Ok "$($p.Count) programs written to $File"
    return $p.Count
}

function Install-LocalInstallers {
    param([string]$Folder)
    Head "Install from folder $Folder"
    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe' } | Sort-Object Name)
    if ($files.Count -eq 0) { Fail 'No .msi or .exe installers in that folder.'; return }
    $i = 0
    foreach ($f in $files) {
        Test-Cancel
        $i++
        Set-Progress ([math]::Round(100 * ($i - 1) / $files.Count)) "Installing $i/$($files.Count): $($f.Name)"
        if ($f.Extension -eq '.msi') {
            Info "[$i/$($files.Count)] $($f.Name) - silent MSI install"
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$($f.FullName)`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -in 0, 3010) { Done "Installed $($f.BaseName)"; if ($p.ExitCode -eq 3010) { $sync.RebootNeeded = $true } } else { Fail "$($f.Name) exit code $($p.ExitCode)" }
        } else {
            Info "[$i/$($files.Count)] $($f.Name) - opening the installer, finish it on screen..."
            $p = Start-Process -FilePath $f.FullName -Wait -PassThru
            if ($p.ExitCode -in 0, 3010) { Done "Ran installer $($f.BaseName)" } else { Warn "$($f.Name) closed with code $($p.ExitCode)" }
        }
    }
    Set-Progress 100
}

$BloatPatterns = @(
    'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.WindowsFeedbackHub', 'Microsoft.ZuneVideo',
    'Microsoft.MicrosoftOfficeHub', 'Microsoft.SkypeApp', 'Microsoft.Microsoft3DViewer', 'Microsoft.MixedReality.Portal',
    'Clipchamp.Clipchamp', 'Microsoft.549981C3F5F10', 'Microsoft.WindowsMaps', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxApp', 'MicrosoftTeams', 'Microsoft.Windows.DevHome',
    'Microsoft.MicrosoftJournal', 'king.com.*', '*Disney*', '*TikTok*', '*Facebook*', '*Instagram*', '*AmazonVideo*', '*SpotifyAB*', '*CandyCrush*'
)

function Remove-Bloatware {
    Head 'Remove built-in junk apps'
    Info 'Keeps: Store, Photos, Calculator, Notepad, Paint, Snipping Tool, Media Player, Outlook, Quick Assist, Phone Link, Xbox sign-in.'
    $n = 0
    foreach ($pat in $BloatPatterns) {
        Test-Cancel
        foreach ($p in @(Get-AppxPackage -AllUsers -Name $pat -ErrorAction SilentlyContinue)) {
            try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $n++; Ok "Removed $($p.Name)" }
            catch { try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $n++; Ok "Removed $($p.Name) (this user)" } catch { Dim "Could not remove $($p.Name)" } }
        }
        foreach ($p in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pat })) {
            try { Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop | Out-Null; Dim "Unprovisioned $($p.DisplayName) for new users" } catch { }
        }
    }
    if ($n) { Done "Removed $n built-in junk app(s)" } else { Ok 'Nothing to remove - already clean.' }
}


# ---- cleanup -------------------------------------------------------------------------------
function Get-FolderSizeMB {
    param([string[]]$Paths)
    $t = 0
    foreach ($p in $Paths) { if ($p -and (Test-Path -LiteralPath $p)) { $t += (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } }
    return [math]::Round($t / 1MB)
}

function Clear-Folder {
    param([string]$Path, [string]$Filter = '*')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Get-ChildItem -LiteralPath $Path -Filter $Filter -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-Cleanup {
    param([string[]]$What)
    Head 'Cleanup'
    $temp = @($env:TEMP, (Join-Path $env:SystemRoot 'Temp'))
    $before = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
    if ($What -contains 'temp') {
        Info "Temp files: about $(Get-FolderSizeMB $temp) MB. Files in use are skipped."
        foreach ($p in $temp) { Clear-Folder $p }
        Done 'Temp files cleared (user + Windows)'
    }
    if ($What -contains 'bin') {
        try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
        Done 'Recycle Bin emptied (permanent)'
    }
    if ($What -contains 'wu') {
        $sd = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        Info "Windows Update download cache: about $(Get-FolderSizeMB @($sd)) MB."
        Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
        Clear-Folder $sd
        Get-ChildItem $env:SystemRoot -Directory -Filter 'SoftwareDistribution.old-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $env:SystemRoot 'System32') -Directory -Filter 'catroot2.old-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service bits, wuauserv -ErrorAction SilentlyContinue
        Done 'Windows Update cache cleared'
    }
    if ($What -contains 'extra') {
        Clear-Folder (Join-Path $env:SystemRoot 'Prefetch')
        Clear-Folder (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') 'thumbcache_*'
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
        Clear-Folder (Join-Path $env:SystemRoot 'Logs\CBS') '*.cab'
        Done 'Prefetch, thumbnails, delivery-optimisation and old CBS logs cleared'
    }
    if ($What -contains 'diskcleanup') {
        Info 'Running Windows Disk Cleanup with every safe option (Downloads and Recycle Bin are NOT touched)...'
        $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        foreach ($k in (Get-ChildItem $vc -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -in 'DownloadsFolder', 'Recycle Bin') { continue }
            try { New-ItemProperty -Path $k.PSPath -Name 'StateFlags0777' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null } catch { }
        }
        Start-Process cleanmgr.exe -ArgumentList '/sagerun:777' -Wait -WindowStyle Minimized
        Done 'Windows Disk Cleanup finished'
    }
    if ($What -contains 'winsxs') {
        Info 'Cleaning the component store (WinSxS). 5-20 minutes...'
        $c = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($c -eq 0) { Done 'Component store (WinSxS) cleaned' } else { Warn "DISM finished with code $c." }
    }
    $after = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
    $freed = [math]::Round(($after - $before) / 1MB)
    if ($freed -gt 0) { Ok "Freed about $freed MB on $env:SystemDrive. Free now: $([math]::Round($after / 1GB, 1)) GB." }
    else { Info "Free on $($env:SystemDrive): $([math]::Round($after / 1GB, 1)) GB." }
}

function Invoke-OptimizeDrives {
    Head 'Optimise drives (TRIM for SSD, defrag for HDD)'
    foreach ($v in (Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystemType -eq 'NTFS' })) {
        Test-Cancel
        Info "Optimising $($v.DriveLetter): ..."
        try { Optimize-Volume -DriveLetter $v.DriveLetter -ErrorAction Stop; Ok "$($v.DriveLetter): optimised" } catch { Warn "$($v.DriveLetter): $($_.Exception.Message)" }
    }
    Done 'Drives optimised'
}

function Show-BigFiles {
    param([string]$Root = $env:SystemDrive + '\Users')
    Head "Biggest files under $Root"
    Info 'Searching, this can take a minute...'
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 25 |
        Out-Table -Property @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB) } }, @{ n = 'Modified'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd') } }, FullName
}

function Show-StartupApps {
    Head 'Apps that start with Windows'
    Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Out-Table -Property Name, User, Location, Command
    Info 'Disable the ones you do not need in Task Manager > Startup apps.'
}

# ---- repair ----------------------------------------------------------------------------------
function Invoke-Repair {
    param([string]$What)
    switch ($What) {
        'sfc' {
            Head 'System File Checker (sfc /scannow)'
            Info 'Checks every Windows file and repairs damaged ones. 10-20 minutes.'
            $c = Invoke-Native sfc.exe @('/scannow')
            if ($c -eq 0) { Done 'SFC scan completed' } else { Warn "SFC finished with code $c. If it could not fix everything, run DISM RestoreHealth, then SFC again." }
        }
        'dism-check' { Head 'DISM CheckHealth'; Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/CheckHealth') | Out-Null }
        'dism-scan' { Head 'DISM ScanHealth'; Info 'A few minutes...'; Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/ScanHealth') | Out-Null }
        'dism' {
            Head 'DISM RestoreHealth'
            Info 'Repairs the Windows image from Windows Update. 10-30 minutes; it may look stuck at 62% - that is normal.'
            $c = Invoke-Native dism.exe @('/Online', '/Cleanup-Image', '/RestoreHealth')
            if ($c -eq 0) { Done 'DISM RestoreHealth completed - Windows image repaired' } else { Fail "DISM finished with code $c. Needs working internet / Windows Update." }
        }
        'chkdsk-scan' {
            Head "Check disk $env:SystemDrive (online scan, no restart)"
            $c = Invoke-Native chkdsk.exe @($env:SystemDrive, '/scan')
            if ($c -eq 0) { Ok 'No problems found.' } else { Warn 'Problems found. Use "Schedule full disk repair" and restart.' }
        }
        'chkdsk-fix' {
            Head "Schedule full disk repair on $env:SystemDrive"
            $p = Start-Process cmd.exe -ArgumentList "/c echo Y| chkdsk $env:SystemDrive /f /r" -Wait -PassThru -WindowStyle Hidden
            Done "Full disk repair (chkdsk /f /r) scheduled for the next restart"
            Warn 'The repair runs before Windows starts and can take an hour or more on a big disk. Do not switch off.'
            $sync.RebootNeeded = $true
        }
        'explorer' { Head 'Restart File Explorer'; Restart-Explorer; Ok 'Explorer restarted.' }
        'icons' {
            Head 'Rebuild the icon and thumbnail cache'
            Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
            Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'IconCache.db') -Force -ErrorAction SilentlyContinue
            Clear-Folder (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') 'iconcache_*'
            Clear-Folder (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') 'thumbcache_*'
            Invoke-Native ie4uinit.exe @('-show') -Quiet | Out-Null
            if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
            Done 'Icon cache rebuilt'
        }
        'store' { Head 'Reset Microsoft Store cache'; Start-Process wsreset.exe; Done 'Microsoft Store cache reset (the Store opens when it finishes)' }
        'startmenu' {
            Head 'Repair Start menu and taskbar'
            foreach ($n in 'Microsoft.Windows.StartMenuExperienceHost', 'Microsoft.Windows.ShellExperienceHost', 'MicrosoftWindows.Client.CBS') {
                foreach ($p in @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)) {
                    try { Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $p.InstallLocation 'AppxManifest.xml') -ErrorAction Stop; Ok "Re-registered $n" } catch { Dim "$n : $($_.Exception.Message)" }
                }
            }
            Restart-Explorer
            Done 'Start menu and taskbar components re-registered'
        }
        'time' {
            Head 'Repair Windows Time'
            Stop-Service w32time -Force -ErrorAction SilentlyContinue
            Invoke-Native w32tm.exe @('/unregister') -Quiet | Out-Null
            Invoke-Native w32tm.exe @('/register') -Quiet | Out-Null
            Set-Service w32time -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service w32time -ErrorAction SilentlyContinue
            Invoke-Native w32tm.exe @('/config', '/manualpeerlist:time.windows.com,0x9 pool.ntp.org,0x9', '/syncfromflags:manual', '/update') -Quiet | Out-Null
            $c = Invoke-Native w32tm.exe @('/resync', '/force')
            if ($c -eq 0) { Done 'Windows Time service repaired and clock synchronised' } else { Warn 'Service repaired, but the sync failed. Check the internet / firewall (UDP 123).' }
        }
        'events' {
            Head 'Critical and error events, last 7 days'
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 500 -ErrorAction SilentlyContinue)
            if ($ev.Count -eq 0) { Ok 'No critical or error events in the System log.'; return }
            $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
                $e = $_.Group[0]
                $msg = ([string]$e.Message -split "`n")[0]
                if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
                [pscustomobject]@{ Count = $_.Count; Last = $e.TimeCreated.ToString('MM-dd HH:mm'); Source = $e.ProviderName; Id = $e.Id; Message = $msg }
            } | Out-Table
            Info "$($ev.Count) events in total."
        }
        'bsod' {
            Head 'Blue screens (crash dumps)'
            $d = @(Get-ChildItem (Join-Path $env:SystemRoot 'Minidump') -Filter *.dmp -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($d.Count -eq 0) { Ok 'No blue-screen crash dumps on this PC.' }
            else { $d | Select-Object -First 15 | Out-Table -Property @{ n = 'When'; e = { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') } }, Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB) } } }
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = (Get-Date).AddDays(-60) } -MaxEvents 10 -ErrorAction SilentlyContinue)
            foreach ($e in $ev) { Dim ("{0}  {1}" -f $e.TimeCreated.ToString('yyyy-MM-dd HH:mm'), (([string]$e.Message -split "`n")[0])) }
        }
    }
}

function Invoke-RestartMode {
    param([string]$Mode)
    switch ($Mode) {
        'bios' {
            Head 'Restart into BIOS / UEFI setup'
            $c = Invoke-Native shutdown.exe @('/r', '/fw', '/t', '5')
            if ($c -eq 0) { Ok 'Restarting into the firmware setup in 5 seconds...' } else { Fail 'This PC does not support restarting into firmware (legacy BIOS). Press the setup key (F2/Del) at power-on.' }
        }
        'advanced' { Head 'Restart into Advanced Startup'; Invoke-Native shutdown.exe @('/r', '/o', '/t', '5') | Out-Null; Ok 'Restarting into the recovery options in 5 seconds...' }
        'safe' {
            Head 'Next start in Safe Mode'
            $c = Invoke-Native bcdedit.exe @('/set', '{current}', 'safeboot', 'minimal')
            if ($c -eq 0) { Done 'Safe Mode set for the next start'; Warn 'Come back here and use "Leave Safe Mode" when finished, or it keeps starting in Safe Mode.' }
        }
        'unsafe' {
            Head 'Leave Safe Mode'
            $c = Invoke-Native bcdedit.exe @('/deletevalue', '{current}', 'safeboot')
            if ($c -eq 0) { Done 'Safe Mode removed - the next start is normal' } else { Info 'Safe Mode was not set.' }
        }
        'now' { Head 'Restart'; Invoke-Native shutdown.exe @('/r', '/t', '5', '/c', 'TQNY-Setup: restarting') | Out-Null; Ok 'Restarting in 5 seconds...' }
    }
}

# ---- health and system information ------------------------------------------------------------
function Get-FirmwareInfo {
    $r = @{ Mode = '-'; SecureBoot = '-'; Tpm = '-' }
    $r.Mode = if ($env:firmware_type) { $env:firmware_type } else { '-' }
    try { $r.SecureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'On' } else { 'Off' } }
    catch { $r.SecureBoot = if ($_.Exception -is [System.UnauthorizedAccessException]) { 'needs admin' } else { 'Not supported' } }
    try {
        $t = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
        if ($t) { $r.Tpm = 'TPM ' + ([string]$t.SpecVersion).Split(',')[0].Trim() + $(if ($t.IsEnabled_InitialValue) { ' enabled' } else { ' disabled' }) } else { $r.Tpm = 'None' }
    } catch { $r.Tpm = 'Not readable' }
    return $r
}

function Get-ActivationText {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Windows*' } | Select-Object -First 1
    if (-not $lic) { return 'Unknown' }
    switch ($lic.LicenseStatus) { 1 { 'Activated' } 0 { 'Unlicensed' } 2 { 'Grace period' } 3 { 'Grace period' } 5 { 'Notification - NOT activated' } default { 'NOT activated' } }
}

function Test-PendingReboot {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    $p = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($p) { return $true }
    $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $b = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($a -and $b -and $a -ne $b) { return $true }
    return $false
}

function Invoke-HealthCheck {
    Head 'Health check - read only, nothing is changed'
    $ErrorActionPreference = 'SilentlyContinue'
    $os = Get-CimInstance Win32_OperatingSystem
    $ed = Get-WindowsEdition
    Info "Windows        : $($os.Caption)  $($ed.Display)  build $($ed.Build).$($ed.UBR)"
    $up = (Get-Date) - $os.LastBootUpTime
    Info ("Uptime         : {0}d {1}h" -f [int][math]::Floor($up.TotalDays), $up.Hours)
    if ($up.TotalDays -gt 14) { Warn 'Not restarted for over two weeks.' }
    $act = Get-ActivationText
    if ($act -eq 'Activated') { Ok "Activation     : $act" } else { Warn "Activation     : $act" }
    $fw = Get-FirmwareInfo
    Info "Firmware       : $($fw.Mode)   Secure Boot: $($fw.SecureBoot)   $($fw.Tpm)"
    foreach ($d in Get-PhysicalDisk) {
        $line = "Disk           : $($d.FriendlyName)  $($d.MediaType)  $([math]::Round($d.Size / 1GB)) GB  -> $($d.HealthStatus)"
        if ($d.HealthStatus -eq 'Healthy') { Ok $line } else { Fail $line }
        $rc = $d | Get-StorageReliabilityCounter
        if ($rc) {
            $extra = @()
            if ($null -ne $rc.Wear) { $extra += "wear $($rc.Wear)%" }
            if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) { $extra += "temp $($rc.Temperature)C" }
            if ($rc.ReadErrorsUncorrected) { $extra += "uncorrected read errors $($rc.ReadErrorsUncorrected)" }
            if ($null -ne $rc.PowerOnHours) { $extra += "power-on $($rc.PowerOnHours) h" }
            if ($extra.Count) { Dim ('                 ' + ($extra -join ', ')) }
        }
    }
    foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemType -and $_.Size -gt 0 })) {
        $fp = [math]::Round($v.SizeRemaining / $v.Size * 100)
        $line = "Free space     : $($v.DriveLetter): $([math]::Round($v.SizeRemaining / 1GB)) GB of $([math]::Round($v.Size / 1GB)) GB ($fp%)"
        if ($fp -lt 10) { Fail ($line + '  <-- LOW') } else { Info $line }
    }
    $cs = Get-CimInstance Win32_ComputerSystem
    $used = [math]::Round(100 - ($os.FreePhysicalMemory * 1KB) / $cs.TotalPhysicalMemory * 100)
    Info "Memory         : $([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB, $used% in use now"
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct
    if ($av) { foreach ($a in $av) { Info "Antivirus      : $($a.displayName)" } } else { Warn 'Antivirus      : none reported' }
    try { $m = Get-MpComputerStatus -ErrorAction Stop; if ($m.RealTimeProtectionEnabled) { Ok 'Defender       : real-time protection ON' } else { Warn 'Defender       : real-time protection OFF' } } catch { }
    $fwp = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled })
    if ($fwp.Count) { Warn ('Firewall       : OFF for ' + (($fwp | ForEach-Object { $_.Name }) -join ', ')) } else { Ok 'Firewall       : on for every profile' }
    $bl = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if ($bl) { foreach ($b in $bl) { Info "BitLocker      : $($b.MountPoint) $($b.ProtectionStatus) ($($b.VolumeStatus))" } } else { Info 'BitLocker      : not readable / not available' }
    if (Test-PendingReboot) { Warn 'Pending reboot : YES - this PC needs restarting' } else { Ok 'Pending reboot : no' }
    $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($hf) {
        $age = [int]((Get-Date) - $hf.InstalledOn).TotalDays
        $line = "Last update    : $($hf.HotFixID) on $($hf.InstalledOn.ToString('yyyy-MM-dd')) ($age days ago)"
        if ($age -gt 45) { Warn $line } else { Info $line }
    }
    $bat = Get-CimInstance Win32_Battery
    foreach ($x in $bat) { Info "Battery        : $($x.EstimatedChargeRemaining)% remaining" }
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
    if ($bad.Count) { Warn "Devices        : $($bad.Count) with driver problems (see Drivers)" } else { Ok 'Devices        : all drivers working' }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 300)
    Info "Errors 7 days  : $($ev.Count) critical or error events in the System log"
    Log ''
    Dim 'Nothing above was changed. This only reports.'
}

function Get-SystemSpec {
    $ErrorActionPreference = 'SilentlyContinue'
    $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem; $bi = Get-CimInstance Win32_BIOS
    $bb = Get-CimInstance Win32_BaseBoard; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ed = Get-WindowsEdition; $fw = Get-FirmwareInfo
    $l = [ordered]@{}
    $l['Computer name'] = $env:COMPUTERNAME
    $l['Manufacturer'] = $cs.Manufacturer
    $l['Model'] = $cs.Model
    $l['Serial number'] = Get-RealSerial $bi.SerialNumber
    $l['Motherboard'] = "$($bb.Manufacturer) $($bb.Product)"
    $l['BIOS'] = "$($bi.SMBIOSBIOSVersion)  ($(if ($bi.ReleaseDate) { $bi.ReleaseDate.ToString('yyyy-MM-dd') }))"
    $l['Firmware'] = "$($fw.Mode), Secure Boot $($fw.SecureBoot), $($fw.Tpm)"
    $l['Processor'] = ([string]$cpu.Name).Trim() + "  ($($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads)"
    $mods = @(Get-CimInstance Win32_PhysicalMemory)
    $l['Memory'] = "$([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB  (" + (($mods | ForEach-Object { "$([math]::Round($_.Capacity / 1GB))GB@$($_.Speed)" }) -join ' + ') + ')'
    $i = 0
    foreach ($d in (Get-PhysicalDisk)) { $i++; $l["Disk $i"] = "$($d.FriendlyName)  $($d.MediaType)  $($d.BusType)  $([math]::Round($d.Size / 1GB)) GB  $($d.HealthStatus)" }
    $i = 0
    foreach ($g in (Get-CimInstance Win32_VideoController)) { $i++; $l["Graphics $i"] = "$($g.Name)  (driver $($g.DriverVersion))" }
    $l['Windows'] = "$($os.Caption)  $($ed.Display)  build $($ed.Build).$($ed.UBR)  $($os.OSArchitecture)"
    $l['Installed on'] = if ($os.InstallDate) { $os.InstallDate.ToString('yyyy-MM-dd') } else { '-' }
    $l['Activation'] = Get-ActivationText
    $l['Domain / workgroup'] = if ($cs.PartOfDomain) { "domain $($cs.Domain)" } else { "workgroup $($cs.Workgroup)" }
    $l['Logged on as'] = "$env:USERDOMAIN\$env:USERNAME"
    foreach ($a in (Get-NetAdapter -Physical)) { $l["NIC $($a.Name)"] = "$($a.InterfaceDescription)  $($a.MacAddress)  $($a.Status)" }
    return $l
}

function Show-SystemSpec {
    Head 'System information'
    $l = Get-SystemSpec
    foreach ($k in $l.Keys) { Info ("{0,-20}: {1}" -f $k, $l[$k]) }
}

function Get-DashboardData {
    $ErrorActionPreference = 'SilentlyContinue'
    $d = @{}
    $cs = Get-CimInstance Win32_ComputerSystem; $os = Get-CimInstance Win32_OperatingSystem; $bi = Get-CimInstance Win32_BIOS
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ed = Get-WindowsEdition
    $d.Computer = $env:COMPUTERNAME
    $d.ComputerSub = if ($cs.PartOfDomain) { "Domain $($cs.Domain)" } else { "Workgroup $($cs.Workgroup)" }
    $d.Model = ([string]$cs.Model).Trim()
    $mk = (([string]$cs.Manufacturer) -replace '\s*(Technology|Computer|Inc\.?|Co\.,?|Ltd\.?|Corporation|International)\b.*$', '').Trim()
    $d.ModelSub = "$mk   serial $(Get-RealSerial $bi.SerialNumber)"
    $d.Windows = ([string]$os.Caption) -replace '^Microsoft\s+', ''
    $d.WindowsSub = "$($ed.Display)  build $($ed.Build).$($ed.UBR)"
    $d.Activation = Get-ActivationText
    $d.ActivationSub = $ed.Edition
    $d.Cpu = ([string]$cpu.Name -replace '\(R\)|\(TM\)|CPU|Processor', '' -replace '\s+', ' ').Trim()
    $d.CpuSub = "$($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
    $used = [math]::Round(100 - ($os.FreePhysicalMemory * 1KB) / $cs.TotalPhysicalMemory * 100)
    $d.Memory = "$([math]::Round($cs.TotalPhysicalMemory / 1GB)) GB"
    $d.MemorySub = "$used% in use"
    $v = Get-Volume -DriveLetter ($env:SystemDrive.TrimEnd(':'))
    $pd = Get-PhysicalDisk | Select-Object -First 1
    $d.Storage = "$([math]::Round($v.SizeRemaining / 1GB)) GB free"
    $d.StorageSub = "of $([math]::Round($v.Size / 1GB)) GB on $env:SystemDrive   $($pd.MediaType) $($pd.HealthStatus)"
    $d.StorageLow = ($v.Size -gt 0 -and ($v.SizeRemaining / $v.Size) -lt 0.1)
    $a = Get-ActiveAdapter
    if ($a) {
        $c = Get-NetIPConfiguration -InterfaceIndex $a.ifIndex
        $d.Network = [string](@($c.IPv4Address)[0].IPAddress)
        $d.NetworkSub = "$($a.Name)  gw $([string](@($c.IPv4DefaultGateway)[0].NextHop))"
    } else { $d.Network = 'Not connected'; $d.NetworkSub = 'No active physical adapter' }
    $t = Get-WebText 'http://www.msftconnecttest.com/connecttest.txt' 5000
    $d.Internet = if ($t -and $t -match 'Microsoft Connect Test') { 'Online' } else { 'Offline' }
    $d.InternetSub = if ($d.Internet -eq 'Online') { 'DNS and web reachable' } else { 'Run Network > Check the internet' }
    try { $m = Get-MpComputerStatus -ErrorAction Stop; $d.Security = if ($m.RealTimeProtectionEnabled) { 'Protected' } else { 'Real-time OFF' } } catch {
        $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct)
        $d.Security = if ($av.Count) { [string]$av[0].displayName } else { 'No antivirus' }
    }
    $fwOff = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled })
    $d.SecuritySub = if ($fwOff.Count) { 'Firewall OFF: ' + (($fwOff | ForEach-Object { $_.Name }) -join ', ') } else { 'Firewall on' }
    $up = (Get-Date) - $os.LastBootUpTime
    $d.Uptime = '{0}d {1}h' -f [int][math]::Floor($up.TotalDays), $up.Hours
    $d.UptimeSub = if (Test-PendingReboot) { 'Restart pending' } else { 'Booted ' + $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm') }
    $fw = Get-FirmwareInfo
    $d.Firmware = "$($fw.Mode)"
    $d.FirmwareSub = "Secure Boot $($fw.SecureBoot), $($fw.Tpm)"
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count
    $d.Drivers = if ($bad) { "$bad problem(s)" } else { 'All working' }
    $d.DriversSub = 'Device Manager status'
    return $d
}

# ---- handover sheet ------------------------------------------------------------------------------
function ConvertTo-Html5 { param([string]$s) return [System.Net.WebUtility]::HtmlEncode($s) }

function New-HandoverReport {
    param([string]$Customer, [string]$Contact, [string]$Notes, [string]$OldName)
    Head 'Handover sheet'
    if (-not $sync.LastNet) { Info 'Checking the network first, so the sheet records it...'; [void](Test-Internet) }
    $net = $sync.LastNet
    $spec = Get-SystemSpec
    $co = $Cfg.Company
    $stamp = Get-Stamp
    $dir = Join-Path $Cfg.DataDir 'handover'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $base = Join-Path $dir ("{0}-{1}" -f $env:COMPUTERNAME, $stamp)
    $after = if ($sync.NewName) { "$($sync.NewName) (after restart)" } else { 'unchanged' }
    $done = @($sync.Done)
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm'

    # Plain text copy, the same as v3.x
    $t = New-Object System.Collections.ArrayList
    $line = '=' * 63
    foreach ($x in @($line, " $($co.Name)", " $($co.Site)   $($co.Store)", " $($co.CR)   $($co.Maroof)", " $($co.Mail)   $($co.Phone)", $line, '', ' PC HANDOVER SHEET', '',
            " Date        : $when", " Technician  : $($Cfg.Tech)", " Site        : $($Cfg.Site)", " Customer    : $Customer", " Contact     : $Contact", '',
            " Computer name before : $OldName", " Computer name after  : $after", " Hardware ID          : $($Facts.FP) ($($Facts.FPType))", '',
            ' ---------------------------------------------------------------', ' SPECIFICATION', ' ---------------------------------------------------------------')) { [void]$t.Add($x) }
    foreach ($k in $spec.Keys) { [void]$t.Add((" {0,-20}: {1}" -f $k, $spec[$k])) }
    foreach ($x in @('', ' ---------------------------------------------------------------', ' NETWORK AT HANDOVER', ' ---------------------------------------------------------------',
            " Adapter   : $($net.NIC)", " IPv4      : $($net.IPv4)", " Gateway   : $($net.GW)", " DNS       : $($net.DNS)", " Internet  : DNS=$($net.DnsOk)  WEB=$($net.WebOk)", '',
            ' ---------------------------------------------------------------', ' WORK CARRIED OUT', ' ---------------------------------------------------------------')) { [void]$t.Add($x) }
    if ($done.Count) { foreach ($x in $done) { [void]$t.Add(" - $x") } } else { [void]$t.Add(' - (no changes recorded by the tool in this session)') }
    if ($Notes) { [void]$t.Add(''); [void]$t.Add(' Notes:'); foreach ($x in ($Notes -split "`r?`n")) { [void]$t.Add("   $x") } }
    foreach ($x in @('', ' ---------------------------------------------------------------', " Prepared with TQNY-Setup v$($Cfg.Version)", " $($co.Site)  -  $($co.Mail)  -  $($co.Phone)", $line)) { [void]$t.Add($x) }
    Set-Content -LiteralPath "$base.txt" -Value $t.ToArray() -Encoding UTF8

    # Printable HTML copy
    $h = New-Object System.Text.StringBuilder
    $e = { param($s) ConvertTo-Html5 ([string]$s) }
    [void]$h.Append('<!doctype html><html><head><meta charset="utf-8"><title>PC handover - ' + (& $e $env:COMPUTERNAME) + '</title><style>')
    [void]$h.Append('body{font-family:Segoe UI,Arial,sans-serif;color:#1b2430;margin:0;background:#eef2f5}main{max-width:820px;margin:24px auto;background:#fff;padding:36px 44px;border-radius:10px;box-shadow:0 2px 14px rgba(0,0,0,.08)}')
    [void]$h.Append('header{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:3px solid #0e9fb3;padding-bottom:14px}h1{font-size:22px;margin:0;color:#0b7f8f}header p{margin:2px 0;font-size:12px;color:#5b6775}')
    [void]$h.Append('h2{font-size:14px;text-transform:uppercase;letter-spacing:.06em;color:#0b7f8f;margin:26px 0 8px}table{width:100%;border-collapse:collapse;font-size:13px}td{padding:5px 8px;border-bottom:1px solid #e6eaef;vertical-align:top}td:first-child{width:34%;color:#5b6775}')
    [void]$h.Append('ul{margin:6px 0;padding-left:20px;font-size:13px}li{margin:3px 0}.sig{display:flex;gap:40px;margin-top:46px}.sig div{flex:1;border-top:1px solid #9aa5b1;padding-top:6px;font-size:12px;color:#5b6775}footer{margin-top:30px;font-size:11px;color:#8a95a1;text-align:center}.good{color:#1a7f37;font-weight:600}.bad{color:#c62828;font-weight:600}@media print{body{background:#fff}main{box-shadow:none;margin:0}}')
    [void]$h.Append('</style></head><body><main><header><div><h1>PC Handover Sheet</h1><p>' + (& $e $when) + '</p></div><div style="text-align:right">')
    foreach ($x in @($co.Name, "$($co.Site)  |  $($co.Store)", "$($co.CR)  |  $($co.Maroof)", "$($co.Mail)  |  $($co.Phone)")) { [void]$h.Append('<p>' + (& $e $x) + '</p>') }
    [void]$h.Append('</div></header><h2>Job</h2><table>')
    $rowsJob = [ordered]@{ 'Customer' = $Customer; 'Contact' = $Contact; 'Technician' = $Cfg.Tech; 'Site' = $Cfg.Site; 'Computer name before' = $OldName; 'Computer name after' = $after }
    foreach ($k in $rowsJob.Keys) { [void]$h.Append('<tr><td>' + (& $e $k) + '</td><td>' + (& $e $rowsJob[$k]) + '</td></tr>') }
    [void]$h.Append('</table><h2>Specification</h2><table>')
    foreach ($k in $spec.Keys) { [void]$h.Append('<tr><td>' + (& $e $k) + '</td><td>' + (& $e $spec[$k]) + '</td></tr>') }
    [void]$h.Append('</table><h2>Network at handover</h2><table>')
    $inet = if ($net.DnsOk -eq 'YES' -and $net.WebOk -eq 'YES') { '<span class="good">Working</span>' } else { '<span class="bad">Problem</span>' }
    foreach ($p in @(@('Adapter', $net.NIC), @('IPv4 address', $net.IPv4), @('Gateway', $net.GW), @('DNS', $net.DNS))) { [void]$h.Append('<tr><td>' + $p[0] + '</td><td>' + (& $e $p[1]) + '</td></tr>') }
    [void]$h.Append('<tr><td>Internet</td><td>' + $inet + '</td></tr></table><h2>Work carried out</h2><ul>')
    if ($done.Count) { foreach ($x in $done) { [void]$h.Append('<li>' + (& $e $x) + '</li>') } } else { [void]$h.Append('<li>(no changes recorded by the tool in this session)</li>') }
    [void]$h.Append('</ul>')
    if ($Notes) { [void]$h.Append('<h2>Notes</h2><p style="font-size:13px;white-space:pre-wrap">' + (& $e $Notes) + '</p>') }
    [void]$h.Append('<div class="sig"><div>Technician: ' + (& $e $Cfg.Tech) + '</div><div>Customer signature</div></div>')
    [void]$h.Append('<footer>Prepared with TQNY-Setup v' + $Cfg.Version + '  |  ' + (& $e $co.Site) + '</footer></main></body></html>')
    [IO.File]::WriteAllText("$base.html", $h.ToString(), (New-Object System.Text.UTF8Encoding $true))
    Ok 'Handover sheet written:'
    Info "  $base.html"
    Info "  $base.txt"
    Start-Process "$base.html"
    return "$base.html"
}

function New-BatteryReport {
    Head 'Battery report'
    if (-not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) { Info 'This PC has no battery.'; return }
    $f = Join-Path $Cfg.DataDir ("reports\battery-{0}-{1}.html" -f $env:COMPUTERNAME, (Get-Stamp))
    New-Item -ItemType Directory -Path (Split-Path $f) -Force | Out-Null
    Invoke-Native powercfg.exe @('/batteryreport', '/output', $f) -Quiet | Out-Null
    if (Test-Path -LiteralPath $f) { Ok "Battery report: $f"; Start-Process $f } else { Fail 'powercfg could not create the report.' }
}

# ---- backup before a format, restore after ---------------------------------------------------------
function Get-UserProfiles {
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object { Split-Path $_.LocalPath -Leaf } | Sort-Object
}

function Get-ProfilePath {
    param([string]$User)
    $p = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { (Split-Path $_.LocalPath -Leaf) -ieq $User } | Select-Object -First 1
    if ($p) { return $p.LocalPath }
    return (Join-Path (Split-Path $env:PUBLIC) $User)
}

# Where a user's folder really is. For the user running the tool this follows
# OneDrive / folder redirection; for other users it is the usual location.
function Get-UserFolders {
    param([string]$User)
    $prof = Get-ProfilePath $User
    $map = [ordered]@{
        Desktop = Join-Path $prof 'Desktop'; Documents = Join-Path $prof 'Documents'; Downloads = Join-Path $prof 'Downloads'
        Pictures = Join-Path $prof 'Pictures'; Videos = Join-Path $prof 'Videos'; Music = Join-Path $prof 'Music'; Favorites = Join-Path $prof 'Favorites'
    }
    if ($User -ieq $env:USERNAME) {
        $map.Desktop = [Environment]::GetFolderPath('Desktop'); $map.Documents = [Environment]::GetFolderPath('MyDocuments')
        $map.Pictures = [Environment]::GetFolderPath('MyPictures'); $map.Videos = [Environment]::GetFolderPath('MyVideos')
        $map.Music = [Environment]::GetFolderPath('MyMusic'); $map.Favorites = [Environment]::GetFolderPath('Favorites')
        $dl = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($dl) { $map.Downloads = [Environment]::ExpandEnvironmentVariables($dl) }
    } else {
        foreach ($k in @($map.Keys)) {
            $od = Get-ChildItem -LiteralPath $prof -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName $k } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
            if ($od -and -not (Test-Path -LiteralPath $map[$k])) { $map[$k] = $od }
        }
    }
    return @{ Profile = $prof; Folders = $map }
}

function Invoke-Robocopy {
    param([string]$Src, [string]$Dst)
    $c = Invoke-Native robocopy.exe @($Src, $Dst, '/E', '/R:1', '/W:1', '/XJ', '/MT:16', '/NP', '/NFL', '/NDL', '/NJH', '/XF', 'desktop.ini', 'thumbs.db', '*.tmp', '~$*') -Indent '      '
    return ($c -lt 8)
}

function Get-BrowserBookmarkFiles {
    param([string]$Prof)
    $list = @()
    foreach ($b in @(@('Chrome', 'AppData\Local\Google\Chrome\User Data'), @('Edge', 'AppData\Local\Microsoft\Edge\User Data'), @('Brave', 'AppData\Local\BraveSoftware\Brave-Browser\User Data'))) {
        $root = Join-Path $Prof $b[1]
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            $f = Join-Path $d.FullName 'Bookmarks'
            if (Test-Path -LiteralPath $f) { $list += [pscustomobject]@{ Browser = $b[0]; Profile = $d.Name; File = $f; Rel = $b[1] } }
        }
    }
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $Prof 'AppData\Roaming\Mozilla\Firefox\Profiles') -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $d.FullName 'places.sqlite'
        if (Test-Path -LiteralPath $f) { $list += [pscustomobject]@{ Browser = 'Firefox'; Profile = $d.Name; File = $f; Rel = 'AppData\Roaming\Mozilla\Firefox\Profiles' } }
    }
    return $list
}

function Invoke-PcBackup {
    param([hashtable]$Opt)
    Head "Backup before format -> $($Opt.Dest)"
    $dest = $Opt.Dest
    try { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null } catch { Fail "Cannot create $dest : $($_.Exception.Message)"; return }
    $u = Get-UserFolders $Opt.User
    $items = @($Opt.Items)
    $step = 0; $nSteps = $items.Count
    $man = [ordered]@{ Tool = "TQNY-Setup $($Cfg.Version)"; Computer = $env:COMPUTERNAME; User = $Opt.User; Date = (Get-Date -Format 'yyyy-MM-dd HH:mm'); Items = $items }
    if ($items -contains 'files') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Copying user files'
        Head "User files of $($Opt.User)"
        foreach ($k in $u.Folders.Keys) {
            Test-Cancel
            $src = $u.Folders[$k]
            if (-not (Test-Path -LiteralPath $src)) { Dim "$k : not found, skipped"; continue }
            Info "$k  ($src)"
            if (Invoke-Robocopy $src (Join-Path $dest "Files\$k")) { Ok "$k copied" } else { Fail "$k copy reported errors" }
        }
        Done "Backed up the user folders of $($Opt.User)"
    }
    if ($items -contains 'bookmarks') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Browser bookmarks'
        Head 'Browser bookmarks'
        $bm = @(Get-BrowserBookmarkFiles $u.Profile)
        foreach ($b in $bm) {
            $to = Join-Path $dest "Bookmarks\$($b.Browser)\$($b.Profile)"
            New-Item -ItemType Directory -Path $to -Force | Out-Null
            Copy-Item -LiteralPath $b.File -Destination $to -Force -ErrorAction SilentlyContinue
            if ($b.Browser -eq 'Firefox') { Copy-Item -LiteralPath (Join-Path (Split-Path $b.File) 'favicons.sqlite') -Destination $to -Force -ErrorAction SilentlyContinue }
            Ok "$($b.Browser) / $($b.Profile)"
        }
        if ($bm.Count) { Done "Backed up $($bm.Count) browser bookmark file(s)" } else { Info 'No Chrome / Edge / Brave / Firefox bookmarks found.' }
    }
    if ($items -contains 'wifi') { $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Wi-Fi'; [void](Export-WifiProfiles (Join-Path $dest 'WiFi')) }
    if ($items -contains 'drivers') { $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Drivers'; Export-Drivers (Join-Path $dest 'Drivers') }
    if ($items -contains 'apps') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'App list'
        $ad = Join-Path $dest 'Apps'; New-Item -ItemType Directory -Path $ad -Force | Out-Null
        [void](Export-InstalledPrograms (Join-Path $ad 'installed-programs.csv'))
        if (Get-WingetPath) { Invoke-WingetCommand 'export' (Join-Path $ad 'winget-apps.json') } else { Info 'winget not available - only the CSV list was saved.' }
        Done 'Saved the list of installed apps'
    }
    if ($items -contains 'printers') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Printers'
        Head 'Printers (with drivers and ports)'
        $pb = Join-Path $env:SystemRoot 'System32\spool\tools\PrintBrm.exe'
        $pd = Join-Path $dest 'Printers'; New-Item -ItemType Directory -Path $pd -Force | Out-Null
        $pf = Join-Path $pd 'printers.printerExport'
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $pb) {
            $c = Invoke-Native $pb @('-b', '-f', $pf) -Quiet
            if ($c -eq 0 -and (Test-Path -LiteralPath $pf)) { Done 'Backed up printers, ports and drivers' } else { Warn "PrintBrm finished with code $c." }
        } else { Warn 'PrintBrm is not on this edition of Windows. Saving the printer list only.' }
        Get-Printer -ErrorAction SilentlyContinue | Select-Object Name, DriverName, PortName, Shared, ShareName | Export-Csv -LiteralPath (Join-Path $pd 'printers.csv') -NoTypeInformation -Encoding UTF8
    }
    if ($items -contains 'extras') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Outlook and Sticky Notes'
        Head 'Outlook signatures, PST files, Sticky Notes'
        $ex = Join-Path $dest 'Extras'
        $sig = Join-Path $u.Profile 'AppData\Roaming\Microsoft\Signatures'
        if (Test-Path -LiteralPath $sig) { [void](Invoke-Robocopy $sig (Join-Path $ex 'Signatures')); Ok 'Outlook signatures' }
        $sn = Join-Path $u.Profile 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'
        if (Test-Path -LiteralPath $sn) { [void](Invoke-Robocopy $sn (Join-Path $ex 'StickyNotes')); Ok 'Sticky Notes' }
        $pst = @(Get-ChildItem -LiteralPath (Join-Path $u.Profile 'AppData\Local\Microsoft\Outlook') -Filter *.pst -ErrorAction SilentlyContinue)
        foreach ($p in $pst) {
            New-Item -ItemType Directory -Path (Join-Path $ex 'PST') -Force | Out-Null
            try { Copy-Item -LiteralPath $p.FullName -Destination (Join-Path $ex 'PST') -Force -ErrorAction Stop; Ok "PST $($p.Name)" } catch { Warn "$($p.Name) is in use - close Outlook and back up again." }
        }
        Done 'Backed up Outlook signatures / PST files and Sticky Notes'
    }
    if ($items -contains 'info') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'PC information'
        Head 'PC information, keys and network'
        $inf = New-Object System.Collections.ArrayList
        $spec = Get-SystemSpec
        foreach ($k in $spec.Keys) { [void]$inf.Add(("{0,-20}: {1}" -f $k, $spec[$k])) }
        $oem = [string](Get-CimInstance SoftwareLicensingService -ErrorAction SilentlyContinue).OA3xOriginalProductKey
        [void]$inf.Add(''); [void]$inf.Add("OEM Windows key in BIOS: $(if ($oem) { $oem } else { 'none' })")
        [void]$inf.Add(''); [void]$inf.Add('==== BitLocker recovery keys ====')
        foreach ($v in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) { [void]$inf.Add((Get-NativeText manage-bde.exe @('-protectors', '-get', $v.DeviceID))) }
        [void]$inf.Add(''); [void]$inf.Add('==== Mapped drives ===='); [void]$inf.Add((Get-NativeText net.exe @('use')))
        [void]$inf.Add(''); [void]$inf.Add('==== ipconfig /all ===='); [void]$inf.Add((Get-NativeText ipconfig.exe @('/all')))
        Set-Content -LiteralPath (Join-Path $dest 'PC-info.txt') -Value $inf.ToArray() -Encoding UTF8
        Done 'Saved PC information, product key, BitLocker keys, mapped drives and IP settings'
    }
    $man | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dest 'TQNY-Backup.json') -Encoding UTF8
    Set-Progress 100
    $sz = Get-FolderSizeMB @($dest)
    Log ''
    Ok "Backup finished: $dest  ($sz MB)"
    Info 'Check the folder opens on another PC before you format.'
}

function Invoke-PcRestore {
    param([hashtable]$Opt)
    $src = $Opt.Source
    Head "Restore after format <- $src"
    if (-not (Test-Path -LiteralPath $src)) { Fail 'That backup folder does not exist.'; return }
    $u = Get-UserFolders $Opt.User
    $items = @($Opt.Items)
    $step = 0; $nSteps = $items.Count
    if ($items -contains 'files') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Copying user files back'
        Head "User files -> $($Opt.User)"
        foreach ($k in $u.Folders.Keys) {
            Test-Cancel
            $from = Join-Path $src "Files\$k"
            if (-not (Test-Path -LiteralPath $from)) { continue }
            Info "$k  -> $($u.Folders[$k])"
            if (Invoke-Robocopy $from $u.Folders[$k]) { Ok "$k restored" } else { Fail "$k restore reported errors" }
        }
        Done "Restored user files to $($Opt.User)"
    }
    if ($items -contains 'bookmarks') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Bookmarks'
        Head 'Browser bookmarks'
        $map = @{ Chrome = 'AppData\Local\Google\Chrome\User Data'; Edge = 'AppData\Local\Microsoft\Edge\User Data'; Brave = 'AppData\Local\BraveSoftware\Brave-Browser\User Data'; Firefox = 'AppData\Roaming\Mozilla\Firefox\Profiles' }
        foreach ($bd in @(Get-ChildItem -LiteralPath (Join-Path $src 'Bookmarks') -Directory -ErrorAction SilentlyContinue)) {
            $proc = @{ Chrome = 'chrome'; Edge = 'msedge'; Brave = 'brave'; Firefox = 'firefox' }[$bd.Name]
            if ($proc -and (Get-Process $proc -ErrorAction SilentlyContinue)) { Warn "$($bd.Name) is open - close it and restore bookmarks again."; continue }
            foreach ($pd in @(Get-ChildItem -LiteralPath $bd.FullName -Directory -ErrorAction SilentlyContinue)) {
                if ($bd.Name -eq 'Firefox') {
                    $ff = @(Get-ChildItem -LiteralPath (Join-Path $u.Profile $map.Firefox) -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                    if ($ff.Count -eq 0) { Warn 'Firefox has no profile yet. Open Firefox once, close it, then restore again.'; continue }
                    Copy-Item -Path (Join-Path $pd.FullName '*') -Destination $ff[0].FullName -Force
                    Ok "Firefox bookmarks -> $($ff[0].Name)"
                } else {
                    $to = Join-Path $u.Profile ("{0}\{1}" -f $map[$bd.Name], $pd.Name)
                    New-Item -ItemType Directory -Path $to -Force | Out-Null
                    Copy-Item -LiteralPath (Join-Path $pd.FullName 'Bookmarks') -Destination $to -Force
                    Ok "$($bd.Name) bookmarks -> $($pd.Name)"
                }
            }
        }
        Done 'Restored browser bookmarks'
    }
    if ($items -contains 'wifi') { $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Wi-Fi'; if (Test-Path -LiteralPath (Join-Path $src 'WiFi')) { Import-WifiProfiles (Join-Path $src 'WiFi') } }
    if ($items -contains 'drivers') { $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Drivers'; if (Test-Path -LiteralPath (Join-Path $src 'Drivers')) { Install-DriverFolder (Join-Path $src 'Drivers') 'backed-up drivers' } }
    if ($items -contains 'apps') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Apps'
        $j = Join-Path $src 'Apps\winget-apps.json'
        if (Test-Path -LiteralPath $j) { Invoke-WingetCommand 'import' $j } else { Info 'No winget app list in this backup. See Apps\installed-programs.csv for what was installed.' }
    }
    if ($items -contains 'printers') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Printers'
        Head 'Printers'
        $pf = Join-Path $src 'Printers\printers.printerExport'
        $pb = Join-Path $env:SystemRoot 'System32\spool\tools\PrintBrm.exe'
        if ((Test-Path -LiteralPath $pf) -and (Test-Path -LiteralPath $pb)) {
            $c = Invoke-Native $pb @('-r', '-f', $pf, '-o', 'force')
            if ($c -eq 0) { Done 'Restored printers, ports and drivers' } else { Warn "PrintBrm finished with code $c - check Printers." }
        } else { Info 'No printer backup to restore.' }
    }
    if ($items -contains 'extras') {
        $step++; Set-Progress ([math]::Round(100 * $step / ($nSteps + 1))) 'Extras'
        Head 'Outlook signatures, PST files, Sticky Notes'
        $ex = Join-Path $src 'Extras'
        if (Test-Path -LiteralPath (Join-Path $ex 'Signatures')) { [void](Invoke-Robocopy (Join-Path $ex 'Signatures') (Join-Path $u.Profile 'AppData\Roaming\Microsoft\Signatures')); Ok 'Outlook signatures' }
        if (Test-Path -LiteralPath (Join-Path $ex 'StickyNotes')) {
            $sn = Join-Path $u.Profile 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState'
            if (Get-Process 'Microsoft.Notes' -ErrorAction SilentlyContinue) { Warn 'Close Sticky Notes first.' } else { [void](Invoke-Robocopy (Join-Path $ex 'StickyNotes') $sn); Ok 'Sticky Notes' }
        }
        if (Test-Path -LiteralPath (Join-Path $ex 'PST')) {
            $to = Join-Path $u.Folders.Documents 'Outlook Files'
            [void](Invoke-Robocopy (Join-Path $ex 'PST') $to); Ok "PST files -> $to (open them in Outlook: File > Open > Outlook Data File)"
        }
        Done 'Restored Outlook signatures / PST files and Sticky Notes'
    }
    Set-Progress 100
    Log ''
    Ok 'Restore finished.'
}

function Start-Sysinternals {
    param([string]$Exe)
    Head "Sysinternals $Exe"
    $d = Join-Path $Cfg.DataDir 'tools'
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $file = Join-Path $d $Exe
    if (-not (Test-Path -LiteralPath $file)) {
        Info "Downloading https://live.sysinternals.com/$Exe ..."
        if (-not (Get-WebFile "https://live.sysinternals.com/$Exe" $file)) { return }
    }
    Start-Process -FilePath $file -ArgumentList '-accepteula'
    Ok "Started $Exe"
}

# ---- one-click post-format setup ------------------------------------------------------------------
function Invoke-QuickSetup {
    param([hashtable]$Opt)
    $steps = @($Opt.Steps)
    $order = @('restore', 'rename', 'tz', 'power', 'network', 'ping', 'rdp', 'explorer', 'faststartup', 'arabic', 'netfx3', 'bloat', 'share', 'apps', 'activate', 'updates', 'drivers', 'cleanup', 'restorepoint', 'handover')
    $todo = @($order | Where-Object { $steps -contains $_ })
    $results = New-Object System.Collections.ArrayList
    Head "Quick setup - $($todo.Count) step(s)"
    $i = 0
    foreach ($s in $todo) {
        Test-Cancel
        $i++
        $sync.Progress = [math]::Round(100 * ($i - 1) / $todo.Count)
        $sync.Status = "Quick setup step $i/$($todo.Count)"
        $failsBefore = $sync.FailCount
        $label = $s
        try {
            switch ($s) {
                'rename' {
                    $label = 'Rename'
                    $g = Get-RenameGuard
                    if ($g.Blocked) { Warn "Rename skipped: $($g.Reason)" }
                    else {
                        $al = Invoke-NameAllocation -Apply $true -CustomName $Opt.CustomName
                        if ($al.Target) { [void](Invoke-RenamePC -Target $al.Target) }
                    }
                }
                'tz'          { $label = 'Time zone'; Set-TimeZoneSync $Opt.TimeZone }
                'power'       { $label = 'Power'; Set-PowerPlan @('never') }
                'network'     { $label = 'Network visibility'; Enable-NetworkVisibility }
                'ping'        { $label = 'Allow ping'; Set-PingRule $true }
                'rdp'         { $label = 'Remote Desktop'; Set-RemoteDesktop $true }
                'explorer'    { $label = 'Explorer'; Set-ExplorerTweaks @('ext', 'thispc', 'icons') }
                'faststartup' { $label = 'Fast Startup off'; Set-PowerPlan @('faststartup') }
                'arabic'      { $label = 'Arabic keyboard'; Add-ArabicKeyboard }
                'netfx3'      { $label = '.NET 3.5'; Enable-NetFx3 }
                'bloat'       { $label = 'Remove junk apps'; Remove-Bloatware }
                'share'       { $label = 'Shared folder'; if (Get-SmbShare -Name $Opt.ShareName -ErrorAction SilentlyContinue) { Ok "Share $($Opt.ShareName) already exists." } else { New-TqnyShare -Path $Opt.SharePath -Name $Opt.ShareName } }
                'apps'        { $label = 'Apps'; if (@($Opt.Apps).Count) { Install-WingetApps $Opt.Apps } else { Info 'No apps ticked on the Apps page.' } }
                'activate'    { $label = 'Activate Windows'; if ($Opt.WinKey) { Install-WindowsKey $Opt.WinKey } else { Info 'No key given - skipped.' } }
                'updates'     { $label = 'Windows Update'; Install-WindowsUpdates -Kind 'Software' }
                'drivers'     { $label = 'Driver updates'; Install-WindowsUpdates -Kind 'Driver' }
                'cleanup'     { $label = 'Cleanup'; Invoke-Cleanup @('temp', 'extra') }
                'restorepoint' { $label = 'Restore point'; New-TqnyRestorePoint 'TQNY-Setup quick setup' }
                'handover'    { $label = 'Handover sheet'; [void](New-HandoverReport -Customer $Opt.Customer -Contact $Opt.Contact -Notes $Opt.Notes -OldName $Facts.Name) }
                'restore'     { $label = 'Restore backup'; Invoke-PcRestore @{ Source = $Opt.RestoreFrom; User = $env:USERNAME; Items = @('files', 'bookmarks', 'wifi', 'printers', 'extras') } }
            }
            $st = if ($sync.FailCount -gt $failsBefore) { 'CHECK' } else { 'OK' }
            [void]$results.Add([pscustomobject]@{ Step = $label; Result = $st })
        } catch {
            if ("$_" -eq 'TQNY_CANCELLED') { throw }
            Fail "$label : $($_.Exception.Message)"
            [void]$results.Add([pscustomobject]@{ Step = $label; Result = 'FAILED' })
        }
    }
    $sync.Progress = 100
    Head 'Quick setup summary'
    $results | Out-Table
    if ($sync.RebootNeeded) { Warn 'Restart the PC to finish (rename / updates).' }
}

} # end of $WorkerLib

# ===========================================================================
#  WINDOW LAYOUT AND THEME (WPF / XAML)
# ===========================================================================
$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TQNY IT Setup" Width="1340" Height="880" MinWidth="1060" MinHeight="660"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13"
        Background="#0E1117" Foreground="#E6EDF3" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#0E1117"/>
    <SolidColorBrush x:Key="SideBrush" Color="#0A0D12"/>
    <SolidColorBrush x:Key="CardBrush" Color="#151A21"/>
    <SolidColorBrush x:Key="TileBrush" Color="#1A2029"/>
    <SolidColorBrush x:Key="InputBrush" Color="#0B0F14"/>
    <SolidColorBrush x:Key="LineBrush" Color="#262E3A"/>
    <SolidColorBrush x:Key="TextBrush" Color="#E6EDF3"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#8B98A9"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#22B8CF"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#12343B"/>
    <SolidColorBrush x:Key="OkBrush" Color="#3FB950"/>
    <SolidColorBrush x:Key="WarnBrush" Color="#D29922"/>
    <SolidColorBrush x:Key="FailBrush" Color="#F85149"/>
    <SolidColorBrush x:Key="LogBrush" Color="#080B0F"/>

    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#1C2330"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="BorderBrush" Value="#262E3A"/>
      <Setter Property="Padding" Value="9,6"/>
      <Setter Property="MaxWidth" Value="420"/>
    </Style>

    <Style x:Key="ThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border CornerRadius="4" Background="#343E4C"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}" Margin="2"/></Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}" Margin="2"/></Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="NavButton" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#AEB9C7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="7" Margin="10,1,10,1" Padding="12,6">
              <Grid>
                <Border x:Name="Bar" Width="3" CornerRadius="2" Background="{StaticResource AccentBrush}" HorizontalAlignment="Left" Margin="-12,2,0,2" Visibility="Hidden"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#141A22"/>
                <Setter Property="Foreground" Value="#E6EDF3"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#18212C"/>
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Tile" TargetType="Button">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Background" Value="#1A2029"/>
      <Setter Property="BorderBrush" Value="#262E3A"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="Width" Value="236"/>
      <Setter Property="MinHeight" Value="60"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="8" Padding="13,9">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/>
                <Setter TargetName="Bd" Property="Background" Value="#1F2733"/>
              </Trigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="Tag" Value="danger"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#F85149"/>
                <Setter TargetName="Bd" Property="Background" Value="#2A1B1E"/>
              </MultiTrigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="Tag" Value="primary"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="Bd" Property="Background" Value="#3CC8DD"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#3CC8DD"/>
              </MultiTrigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.8"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Tool" TargetType="Button">
      <Setter Property="Foreground" Value="#C9D3DF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="#2C3542" BorderThickness="1" CornerRadius="6" Padding="10,4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/>
                <Setter TargetName="Bd" Property="Background" Value="#141B24"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Background" Value="#0B0F14"/>
      <Setter Property="BorderBrush" Value="#2C3542"/>
      <Setter Property="CaretBrush" Value="#E6EDF3"/>
      <Setter Property="SelectionBrush" Value="#22B8CF"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#3A4656"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="PasswordBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Background" Value="#0B0F14"/>
      <Setter Property="BorderBrush" Value="#2C3542"/>
      <Setter Property="CaretBrush" Value="#E6EDF3"/>
      <Setter Property="SelectionBrush" Value="#22B8CF"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Padding="10,6" Background="Transparent" CornerRadius="4" Margin="3,1">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#26303E"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#12343B"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="MinHeight" Value="32"/>
      <Setter Property="MaxDropDownHeight" Value="360"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="Toggle" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#0B0F14" BorderBrush="#2C3542" BorderThickness="1" CornerRadius="6">
                      <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0" Data="M0,0 L4,4 L8,0" Stroke="#8B98A9" StrokeThickness="1.6"/>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/></Trigger>
                      <Trigger Property="IsChecked" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#22B8CF"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False" Margin="10,0,28,0" VerticalAlignment="Center"
                                Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
              <TextBox x:Name="PART_EditableTextBox" Style="{x:Null}" Visibility="Hidden" Margin="6,0,26,0" Background="Transparent" BorderThickness="0"
                       Foreground="#E6EDF3" CaretBrush="#E6EDF3" VerticalAlignment="Center" IsReadOnly="{TemplateBinding IsReadOnly}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
                <Border Background="#1A212B" BorderBrush="#2C3542" BorderThickness="1" CornerRadius="6" Margin="0,3,0,0"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer Margin="0,3"><StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="ContentSite" Property="Visibility" Value="Hidden"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Margin" Value="0,5,22,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5" BorderBrush="#4A5568" Background="#0B0F14" VerticalAlignment="Center">
                <Path x:Name="Mark" Data="M3,7.5 L6,10.5 L12,4" Stroke="#04161A" StrokeThickness="2.2" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#22B8CF"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#22B8CF"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="#22B8CF"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#151A21"/>
      <Setter Property="BorderBrush" Value="#232B37"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="10"/>
      <Setter Property="Padding" Value="20,16,10,8"/>
      <Setter Property="Margin" Value="0,0,0,14"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="236"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- sidebar -->
    <Border Grid.Column="0" Background="#0A0D12" BorderBrush="#1C232D" BorderThickness="0,0,1,0">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="20,18,16,8">
          <Border Width="38" Height="38" CornerRadius="10" Background="#22B8CF">
            <TextBlock Text="T" FontSize="22" FontWeight="Bold" Foreground="#04161A" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0"/>
          </Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="TQNY" FontSize="17" FontWeight="Bold" Foreground="#FFFFFF"/>
            <TextBlock x:Name="TxtVersion" Text="IT Setup" FontSize="11.5" Foreground="#8B98A9"/>
          </StackPanel>
        </StackPanel>
        <Border DockPanel.Dock="Bottom" Padding="20,10,16,14" BorderBrush="#1C232D" BorderThickness="0,1,0,0">
          <StackPanel>
            <Border x:Name="AdminChip" CornerRadius="5" Padding="8,3" HorizontalAlignment="Left" Background="#12343B">
              <TextBlock x:Name="AdminText" Text="Administrator" FontSize="11" FontWeight="SemiBold" Foreground="#22B8CF"/>
            </Border>
            <TextBlock x:Name="TxtCompany" Margin="0,8,0,0" FontSize="10.5" Foreground="#6B7685" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <ScrollViewer x:Name="NavScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="NavPanel" Margin="0,0,0,10"/>
        </ScrollViewer>
      </DockPanel>
    </Border>

    <!-- main area -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*" MinHeight="200"/>
        <RowDefinition Height="5"/>
        <RowDefinition Height="190" MinHeight="70"/>
      </Grid.RowDefinitions>

      <Border Grid.Row="0" Padding="30,18,26,14" BorderBrush="#1C232D" BorderThickness="0,0,0,1">
        <DockPanel>
          <StackPanel x:Name="ChipPanel" DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center"/>
          <StackPanel>
            <TextBlock x:Name="TxtTitle" Text="Dashboard" FontSize="22" FontWeight="SemiBold" Foreground="#FFFFFF"/>
            <TextBlock x:Name="TxtSubtitle" Margin="0,3,0,0" Foreground="#8B98A9" TextWrapping="Wrap"/>
            <Border x:Name="Banner" Visibility="Collapsed" Margin="0,10,0,0" CornerRadius="6" Padding="10,6" Background="#2A1B1E" BorderBrush="#5A2A2E" BorderThickness="1" HorizontalAlignment="Left">
              <TextBlock x:Name="BannerText" Foreground="#FF9A93" FontSize="12" TextWrapping="Wrap"/>
            </Border>
          </StackPanel>
        </DockPanel>
      </Border>

      <Grid Grid.Row="1" x:Name="PageHost"/>

      <GridSplitter Grid.Row="2" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="#1C232D" ResizeDirection="Rows" ResizeBehavior="PreviousAndNext" Cursor="SizeNS"/>

      <Border Grid.Row="3" Background="#080B0F">
        <DockPanel>
          <Border DockPanel.Dock="Top" Padding="16,6,12,6" BorderBrush="#1C232D" BorderThickness="0,0,0,1">
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                <Button x:Name="BtnStop" Content="Stop" Style="{StaticResource Tool}" IsEnabled="False" ToolTip="Stop the running job"/>
                <Button x:Name="BtnCopy" Content="Copy log" Style="{StaticResource Tool}"/>
                <Button x:Name="BtnSave" Content="Save log" Style="{StaticResource Tool}"/>
                <Button x:Name="BtnClear" Content="Clear" Style="{StaticResource Tool}"/>
                <Button x:Name="BtnLogs" Content="Logs folder" Style="{StaticResource Tool}"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#3FB950"/>
                <TextBlock x:Name="TxtStatus" Text="Ready" Margin="9,0,14,0" Foreground="#C9D3DF" VerticalAlignment="Center"/>
                <ProgressBar x:Name="Prog" Width="240" Height="4" Visibility="Collapsed" Background="#1C232D" Foreground="#22B8CF" BorderThickness="0" Minimum="0" Maximum="100" VerticalAlignment="Center"/>
              </StackPanel>
            </DockPanel>
          </Border>
          <RichTextBox x:Name="LogBox" IsReadOnly="True" Background="#080B0F" Foreground="#C9D3DF" BorderThickness="0"
                       FontFamily="Cascadia Mono, Consolas" FontSize="12.5" Padding="8,6"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <FlowDocument PagePadding="6,4"/>
          </RichTextBox>
        </DockPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@


# ===========================================================================
#  WINDOW: facts, background runner, log, and the control builders
# ===========================================================================

# Everything from here to the end runs inside one try, so a failure while
# building the window shows a message instead of a silent exit (the console
# window is hidden).
try {

# The worker functions are also loaded here for quick read-only calls.
. $WorkerLib

$Facts = Get-MachineFacts
[void]$StartMarks.Add("facts {0:N1}s" -f $StartClock.Elapsed.TotalSeconds)
$State = @{
    Job = $null; Page = $null; Doc = $null; Inited = @{}
    LogBuf = New-Object System.Text.StringBuilder
    LogFile = $null; RebootAsked = $false
}
$UI = @{}
$Pages = [ordered]@{}
$PageInit = @{}
$PageShow = @{}

# ---- load the window ----------------------------------------------------------
try {
    $Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$Xaml)))
} catch {
    [void][System.Windows.MessageBox]::Show("The window could not be built:`n`n$($_.Exception.Message)", 'TQNY IT Setup', 'OK', 'Error')
    return
}
$Ctl = @{}
foreach ($n in 'NavPanel', 'NavScroll', 'PageHost', 'TxtTitle', 'TxtSubtitle', 'Banner', 'BannerText', 'ChipPanel', 'BtnStop', 'BtnCopy', 'BtnSave',
    'BtnClear', 'BtnLogs', 'StatusDot', 'TxtStatus', 'Prog', 'LogBox', 'TxtVersion', 'TxtCompany', 'AdminChip', 'AdminText') {
    $Ctl[$n] = $Window.FindName($n)
}
$Window.Title = "TQNY IT Setup v$($Cfg.Version)  -  $($Facts.Name)"
[void]$StartMarks.Add("window {0:N1}s" -f $StartClock.Elapsed.TotalSeconds)
$State.Doc = $Ctl.LogBox.Document

function Get-Brush { param([string]$Hex) $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex)); $b.Freeze(); return $b }
function Get-Thick { param([double]$L, [double]$T = -1, [double]$R = -1, [double]$B = -1) if ($T -lt 0) { return New-Object Windows.Thickness($L) } return New-Object Windows.Thickness($L, $T, $R, $B) }

$Brush = @{
    text = Get-Brush '#C9D3DF'; ok = Get-Brush '#3FB950'; warn = Get-Brush '#D29922'; fail = Get-Brush '#F85149'
    head = Get-Brush '#22B8CF'; info = Get-Brush '#58A6FF'; dim = Get-Brush '#7D8794'
}
$IconFont = New-Object Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')

# ---- log panel -------------------------------------------------------------------
function Add-LogLine {
    param([string]$Text = '', [string]$Kind = 'text')
    $para = New-Object Windows.Documents.Paragraph
    $para.Margin = Get-Thick 0
    $run = New-Object Windows.Documents.Run
    $run.Text = $Text
    $b = $Brush[$Kind]; if (-not $b) { $b = $Brush.text }
    $run.Foreground = $b
    if ($Kind -eq 'head') { $run.FontWeight = [Windows.FontWeights]::SemiBold }
    $para.Inlines.Add($run)
    $State.Doc.Blocks.Add($para)
    [void]$State.LogBuf.AppendLine($Text)
    if ($State.Doc.Blocks.Count -gt 6000) {
        for ($i = 0; $i -lt 1000; $i++) { $State.Doc.Blocks.Remove($State.Doc.Blocks.FirstBlock) }
    }
}

function Write-LogFile {
    if ($State.LogBuf.Length -eq 0 -or -not $State.LogFile) { return }
    try { [IO.File]::AppendAllText($State.LogFile, $State.LogBuf.ToString()) } catch { }
    [void]$State.LogBuf.Clear()
}

function Invoke-DrainLog {
    param([int]$Max = 400)
    $item = $null; $n = 0
    while ($n -lt $Max -and $sync.Queue.TryDequeue([ref]$item)) { Add-LogLine $item[1] $item[0]; $n++ }
    if ($n -gt 0) { Write-LogFile; $Ctl.LogBox.ScrollToEnd() }
}

# Messages from the window thread (not from a job).
function Say { param([string]$Text, [string]$Kind = 'text') Add-LogLine $Text $Kind; Write-LogFile; $Ctl.LogBox.ScrollToEnd() }

# ---- background runner ----------------------------------------------------------------
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
$Runner = [runspacefactory]::CreateRunspace($iss)
$Runner.ApartmentState = 'STA'
$Runner.ThreadOptions = 'ReuseThread'
$Runner.Open()
$Runner.SessionStateProxy.SetVariable('sync', $sync)
$Runner.SessionStateProxy.SetVariable('Cfg', $Cfg)
$Runner.SessionStateProxy.SetVariable('Facts', $Facts)
$ps0 = [powershell]::Create(); $ps0.Runspace = $Runner
[void]$ps0.AddScript($WorkerLib.ToString()); [void]$ps0.Invoke(); $ps0.Dispose()
[void]$StartMarks.Add("runner {0:N1}s" -f $StartClock.Elapsed.TotalSeconds)

function Set-Busy {
    param([bool]$Busy, [string]$Name = '')
    if ($Busy) {
        $Ctl.StatusDot.Fill = $Brush.warn
        $Ctl.TxtStatus.Text = "Running: $Name"
        $Ctl.Prog.Visibility = 'Visible'; $Ctl.Prog.IsIndeterminate = $true
        $Ctl.BtnStop.IsEnabled = $true
    } else {
        $Ctl.StatusDot.Fill = $Brush.ok
        $Ctl.TxtStatus.Text = 'Ready'
        $Ctl.Prog.Visibility = 'Collapsed'; $Ctl.Prog.IsIndeterminate = $false
        $Ctl.BtnStop.IsEnabled = $false
    }
}

# Run $Script in the background. $Params arrives there as $P. $OnDone runs
# back on the window thread with (output, params).
function Start-Task {
    param([string]$Name, [scriptblock]$Script, [hashtable]$Params = @{}, [scriptblock]$OnDone, [switch]$Admin, [switch]$Silent)
    if ($State.Job) {
        # A quick background read (like the dashboard) should not block a click: queue it.
        if ($State.Job.Silent -and -not $State.Pending -and -not $Silent) {
            $State.Pending = @{ Name = $Name; Script = $Script; Params = $Params; OnDone = $OnDone; Admin = [bool]$Admin }
            Say "  '$Name' will start as soon as '$($State.Job.Name)' finishes." 'dim'
            return $true
        }
        Say "  Busy with '$($State.Job.Name)'. Wait for it to finish, or press Stop." 'warn'
        return $false
    }
    if ($Admin -and -not $Cfg.IsAdmin) {
        Say "  '$Name' needs Administrator. Close the tool and start it again, choosing Yes at the Administrator prompt." 'fail'
        Show-Msg "'$Name' needs Administrator rights.`n`nClose TQNY IT Setup and start it again, then choose Yes at the Administrator prompt." 'Warning'
        return $false
    }
    $sync.Cancel = $false; $sync.Progress = -1; $sync.Status = ''
    $Runner.SessionStateProxy.SetVariable('P', $Params)
    $Runner.SessionStateProxy.SetVariable('Facts', $Facts)
    $ps = [powershell]::Create(); $ps.Runspace = $Runner
    [void]$ps.AddScript("`$ErrorActionPreference = 'Continue'`n" + $Script.ToString())
    if (-not $Silent) { Say ''; Say ("> {0}    {1}" -f $Name, (Get-Date -Format 'HH:mm:ss')) 'info' }
    # Programs already open from this window (Device Manager, Notepad...) are
    # remembered so Stop only ends what the job itself started.
    $before = @()
    if (-not $Silent) { $before = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessId }) }
    $State.Job = @{ Name = $Name; PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Params = $Params; Started = Get-Date; Silent = [bool]$Silent; Before = $before }
    Set-Busy $true $Name
    return $true
}

function Format-Duration { param([int]$s) if ($s -lt 60) { "$s s" } else { '{0} min {1} s' -f [math]::Floor($s / 60), ($s % 60) } }

function Complete-Task {
    $j = $State.Job
    $out = $null; $err = $null
    try { $out = $j.PS.EndInvoke($j.Handle) } catch { $err = $_.Exception }
    Invoke-DrainLog 100000
    $cancelled = [bool]$sync.Cancel
    if ($err) {
        $m = if ($err.InnerException) { $err.InnerException.Message } else { $err.Message }
        if ($m -match 'TQNY_CANCELLED|pipeline has been stopped') { $cancelled = $true } else { Say "  [ERROR] $m" 'fail' }
    }
    $n = 0
    foreach ($e in $j.PS.Streams.Error) {
        if ("$e" -match 'TQNY_CANCELLED') { $cancelled = $true; continue }
        if ($n -lt 8) { Say ("  [note] " + $e.ToString()) 'dim' }
        $n++
    }
    try { $j.PS.Dispose() } catch { }
    $State.Job = $null
    Set-Busy $false
    $secs = [int]((Get-Date) - $j.Started).TotalSeconds
    if ($cancelled) { Say "  Stopped after $(Format-Duration $secs)." 'warn' }
    elseif (-not $j.Silent) { Say "  Finished in $(Format-Duration $secs)." 'dim' }
    Update-RebootChip
    if ($j.OnDone -and -not $cancelled) {
        $res = $null
        if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1]; if ($null -ne $res) { $res = $res.PSObject.BaseObject } }
        try { & $j.OnDone $res $j.Params } catch { Say "  [UI] $($_.Exception.Message)" 'fail' }
    }
    if ($State.Pending -and -not $State.Job) {
        $q = $State.Pending; $State.Pending = $null
        [void](Start-Task -Name $q.Name -Script $q.Script -Params $q.Params -OnDone $q.OnDone -Admin:$q.Admin)
    } elseif ($cancelled) { $State.Pending = $null }
}

function Stop-Task {
    if (-not $State.Job) { return }
    $sync.Cancel = $true
    $Ctl.TxtStatus.Text = 'Stopping... (waits for the current step to let go)'
    try {
        $before = @($State.Job.Before)
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'conhost.exe' -and $before -notcontains $_.ProcessId } | ForEach-Object {
            $kid = $_.ProcessId
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$kid" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $kid -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    try { [void]$State.Job.PS.BeginStop($null, $null) } catch { }
}

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$Timer.Add_Tick({
    try {
        Invoke-DrainLog
        if ($State.Job) {
            if ($sync.Progress -ge 0) { $Ctl.Prog.IsIndeterminate = $false; $Ctl.Prog.Value = [double]$sync.Progress } else { $Ctl.Prog.IsIndeterminate = $true }
            if ($sync.Status -and -not $sync.Cancel) { $Ctl.TxtStatus.Text = "Running: $($State.Job.Name)  -  $($sync.Status)" }
            if ($State.Job.Handle.IsCompleted) { Complete-Task }
        }
    } catch {
        if (-not $State.TickError) { $State.TickError = $true; Say "  [UI] $($_.Exception.Message)" 'fail' }
    }
})

# ---- dialogs ------------------------------------------------------------------------
function Show-Msg { param([string]$Text, [string]$Icon = 'Information') [void][System.Windows.MessageBox]::Show($Window, $Text, 'TQNY IT Setup', 'OK', $Icon) }

function Confirm-UI {
    param([string]$Question, [string]$Detail = '', [switch]$Danger)
    $m = $Question
    if ($Detail) { $m += "`n`n" + $Detail }
    $icon = if ($Danger) { 'Warning' } else { 'Question' }
    return ([System.Windows.MessageBox]::Show($Window, $m, 'TQNY IT Setup - please confirm', 'YesNo', $icon) -eq 'Yes')
}

function Select-Folder {
    param([string]$Desc = 'Choose a folder', [string]$Start = '')
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Desc; $d.ShowNewFolderButton = $true
    if ($Start -and (Test-Path -LiteralPath $Start)) { $d.SelectedPath = $Start }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

function Select-File {
    param([string]$Filter = 'All files (*.*)|*.*', [switch]$Save, [string]$Name = '', [string]$Dir = '')
    $d = if ($Save) { New-Object Microsoft.Win32.SaveFileDialog } else { New-Object Microsoft.Win32.OpenFileDialog }
    $d.Filter = $Filter
    if ($Name) { $d.FileName = $Name }
    if ($Dir -and (Test-Path -LiteralPath $Dir)) { $d.InitialDirectory = $Dir }
    if ($d.ShowDialog($Window)) { return $d.FileName }
    return $null
}

function Request-Cred {
    param([string]$Message)
    try { return (Get-Credential -Message $Message) } catch { return $null }
}

# ---- control builders ------------------------------------------------------------------
function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#E6EDF3', [string]$Weight = 'Normal', [switch]$Wrap)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = Get-Brush $Color
    $t.FontWeight = [Windows.FontWeights]::$Weight
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}

function Add-NavGroup {
    param([string]$Text)
    $t = New-Text $Text.ToUpper() 10.5 '#5C6776' 'SemiBold'
    $t.Margin = Get-Thick 24 12 0 4
    [void]$Ctl.NavPanel.Children.Add($t)
}

function Add-Page {
    param([string]$Id, [string]$Title, [string]$Sub, [string]$Glyph)
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'; $sv.HorizontalScrollBarVisibility = 'Disabled'; $sv.Visibility = 'Collapsed'
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = Get-Thick 30 20 22 16
    $sv.Content = $sp
    # One mouse-wheel notch scrolls a useful distance on these long pages.
    $sv.Add_PreviewMouseWheel({ param($s, $e) $s.ScrollToVerticalOffset($s.VerticalOffset - $e.Delta); $e.Handled = $true })
    [void]$Ctl.PageHost.Children.Add($sv)
    $rb = New-Object Windows.Controls.RadioButton
    $rb.Style = $Window.FindResource('NavButton'); $rb.GroupName = 'nav'; $rb.Tag = $Id
    $h = New-Object Windows.Controls.StackPanel; $h.Orientation = 'Horizontal'
    $ic = New-Object Windows.Controls.TextBlock
    $ic.Text = [string][char][Convert]::ToInt32($Glyph, 16); $ic.FontFamily = $IconFont; $ic.FontSize = 15; $ic.Width = 28; $ic.VerticalAlignment = 'Center'
    $tx = New-Object Windows.Controls.TextBlock; $tx.Text = $Title; $tx.FontSize = 13.5; $tx.VerticalAlignment = 'Center'
    [void]$h.Children.Add($ic); [void]$h.Children.Add($tx)
    $rb.Content = $h
    $rb.Add_Checked({ Show-Page $this.Tag })
    [void]$Ctl.NavPanel.Children.Add($rb)
    $Pages[$Id] = @{ Root = $sv; Body = $sp; Title = $Title; Sub = $Sub; Nav = $rb }
    return $sp
}

function Show-Page {
    param([string]$Id)
    # Checking the nav button raises its Checked event, which calls back here.
    if (-not $Pages[$Id].Nav.IsChecked) { $Pages[$Id].Nav.IsChecked = $true; return }
    foreach ($k in $Pages.Keys) { $Pages[$k].Root.Visibility = if ($k -eq $Id) { 'Visible' } else { 'Collapsed' } }
    $Ctl.TxtTitle.Text = $Pages[$Id].Title
    $Ctl.TxtSubtitle.Text = $Pages[$Id].Sub
    $State.Page = $Id
    if ($PageInit[$Id] -and -not $State.Inited[$Id]) {
        $State.Inited[$Id] = $true
        try { & $PageInit[$Id] } catch { Say "  [UI] $($_.Exception.Message)" 'fail' }
    }
    if ($PageShow[$Id]) { try { & $PageShow[$Id] } catch { Say "  [UI] $($_.Exception.Message)" 'fail' } }
}

function Add-Card {
    param($Page, [string]$Title, [string]$Desc = '')
    $b = New-Object Windows.Controls.Border
    $b.Style = $Window.FindResource('Card')
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Title 15 '#FFFFFF' 'SemiBold'))
    if ($Desc) { $d = New-Text $Desc 12.5 '#8B98A9' -Wrap; $d.Margin = Get-Thick 0 3 12 2; [void]$sp.Children.Add($d) }
    $b.Child = $sp
    [void]$Page.Children.Add($b)
    return $sp
}

function Invoke-UiAction {
    param($Action)
    if (-not $Action) { return }
    try { & $Action } catch { Say "  [UI] $($_.Exception.Message)" 'fail' }
}

function New-Tile {
    param([string]$T, [string]$S = '', [scriptblock]$A, [string]$V = '', [string]$Tip = '', [double]$Wd = 236)
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $Window.FindResource('Tile'); $btn.Width = $Wd
    $sp = New-Object Windows.Controls.StackPanel
    $c1 = '#E6EDF3'; $c2 = '#8B98A9'
    if ($V -eq 'primary') { $c1 = '#04161A'; $c2 = '#0B4A54' } elseif ($V -eq 'danger') { $c1 = '#FF9A93' }
    $t1 = New-Text $T 13 $c1 'SemiBold' -Wrap
    [void]$sp.Children.Add($t1)
    if ($S) { $t2 = New-Text $S 11.5 $c2 -Wrap; $t2.Margin = Get-Thick 0 2 0 0; [void]$sp.Children.Add($t2) }
    $btn.Content = $sp
    if ($V -eq 'primary') { $btn.Background = Get-Brush '#22B8CF'; $btn.BorderBrush = Get-Brush '#22B8CF' }
    $btn.Tag = $V
    $btn.CommandParameter = $A
    if ($Tip) { $btn.ToolTip = $Tip }
    $btn.Add_Click({ Invoke-UiAction $this.CommandParameter })
    return $btn
}

function Add-Tiles {
    param($Card, [object[]]$Tiles)
    $wp = New-Object Windows.Controls.WrapPanel
    $wp.Margin = Get-Thick 0 10 0 0
    foreach ($t in $Tiles) { [void]$wp.Children.Add((New-Tile @t)) }
    [void]$Card.Children.Add($wp)
}

function New-Input {
    param([string]$Key, [string]$Text = '', [double]$Wd = 200, [string]$Tip = '', [switch]$Multi)
    $tb = New-Object Windows.Controls.TextBox
    $tb.Text = $Text; $tb.Width = $Wd
    if ($Multi) { $tb.AcceptsReturn = $true; $tb.TextWrapping = 'Wrap'; $tb.Height = 74; $tb.VerticalContentAlignment = 'Top'; $tb.VerticalScrollBarVisibility = 'Auto' }
    if ($Tip) { $tb.ToolTip = $Tip }
    $UI[$Key] = $tb
    return $tb
}

function New-Pass {
    param([string]$Key, [double]$Wd = 200, [string]$Tip = '')
    $pb = New-Object Windows.Controls.PasswordBox
    $pb.Width = $Wd
    if ($Tip) { $pb.ToolTip = $Tip }
    $UI[$Key] = $pb
    return $pb
}

function New-Combo {
    param([string]$Key, [object[]]$Items = @(), [string]$Selected = '', [double]$Wd = 200, [switch]$Editable, [string]$Tip = '')
    $cb = New-Object Windows.Controls.ComboBox
    $cb.Width = $Wd; $cb.IsEditable = [bool]$Editable
    foreach ($i in $Items) { [void]$cb.Items.Add($i) }
    if ($Selected -and $cb.Items.Contains($Selected)) { $cb.SelectedItem = $Selected } elseif ($cb.Items.Count) { $cb.SelectedIndex = 0 }
    if ($Editable -and $Selected) { $cb.Text = $Selected }
    if ($Tip) { $cb.ToolTip = $Tip }
    $UI[$Key] = $cb
    return $cb
}

# A combo whose items show one text but carry a value in Tag.
function Set-ComboPairs {
    param($Combo, [object[]]$Pairs, [string]$SelectValue = '')
    $Combo.Items.Clear()
    $sel = $null
    foreach ($p in $Pairs) {
        $it = New-Object Windows.Controls.ComboBoxItem
        $it.Content = $p[0]; $it.Tag = $p[1]
        [void]$Combo.Items.Add($it)
        if ($SelectValue -and $p[1] -eq $SelectValue) { $sel = $it }
    }
    if ($sel) { $Combo.SelectedItem = $sel } elseif ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}

function Set-ComboItems {
    param($Combo, [object[]]$Items, [string]$Keep = '')
    $cur = if ($Keep) { $Keep } else { [string]$Combo.Text }
    $Combo.Items.Clear()
    foreach ($i in $Items) { [void]$Combo.Items.Add($i) }
    if ($cur -and $Combo.Items.Contains($cur)) { $Combo.SelectedItem = $cur }
    elseif ($Combo.IsEditable -and $cur) { $Combo.Text = $cur }
    elseif ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}

function New-Check {
    param([string]$Key, [string]$Text, [bool]$Checked = $false, [string]$Tip = '', [double]$Wd = 0)
    $c = New-Object Windows.Controls.CheckBox
    $c.Content = $Text; $c.IsChecked = $Checked
    if ($Wd -gt 0) { $c.Width = $Wd }
    if ($Tip) { $c.ToolTip = $Tip }
    $UI[$Key] = $c
    return $c
}

function Add-Fields {
    param($Card, [object[]]$Fields)
    $wp = New-Object Windows.Controls.WrapPanel
    $wp.Margin = Get-Thick 0 8 0 0
    foreach ($f in $Fields) {
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Margin = Get-Thick 0 4 14 4
        if ($f.L) { $l = New-Text $f.L 11.5 '#8B98A9'; $l.Margin = Get-Thick 0 0 0 5; [void]$sp.Children.Add($l) }
        [void]$sp.Children.Add($f.C)
        [void]$wp.Children.Add($sp)
    }
    [void]$Card.Children.Add($wp)
}

function Add-Checks {
    param($Card, [object[]]$Checks)
    $wp = New-Object Windows.Controls.WrapPanel
    $wp.Margin = Get-Thick 0 8 0 2
    foreach ($c in $Checks) { [void]$wp.Children.Add($c) }
    [void]$Card.Children.Add($wp)
}

function Add-Note {
    param($Card, [string]$Text, [string]$Color = '#7D8794', [string]$Key = '')
    $t = New-Text $Text 12 $Color -Wrap
    $t.Margin = Get-Thick 0 6 12 2
    if ($Key) { $UI[$Key] = $t }
    [void]$Card.Children.Add($t)
}

function Add-SubHead {
    param($Card, [string]$Text)
    $t = New-Text $Text 12 '#22B8CF' 'SemiBold'
    $t.Margin = Get-Thick 0 12 0 0
    [void]$Card.Children.Add($t)
}

# Read a control's value by its key.
function Get-V {
    param([string]$Key)
    $c = $UI[$Key]
    if (-not $c) { return $null }
    if ($c -is [Windows.Controls.PasswordBox]) { return $c.Password }
    if ($c -is [Windows.Controls.TextBox]) { return $c.Text.Trim() }
    if ($c -is [Windows.Controls.CheckBox]) { return [bool]$c.IsChecked }
    if ($c -is [Windows.Controls.ComboBox]) {
        if ($c.SelectedItem -is [Windows.Controls.ComboBoxItem]) { return [string]$c.SelectedItem.Tag }
        if ($c.IsEditable) { return ([string]$c.Text).Trim() }
        return [string]$c.SelectedItem
    }
    return $null
}

function Set-V {
    param([string]$Key, $Value)
    $c = $UI[$Key]
    if (-not $c) { return }
    if ($c -is [Windows.Controls.PasswordBox]) { $c.Password = [string]$Value }
    elseif ($c -is [Windows.Controls.TextBox]) { $c.Text = [string]$Value }
    elseif ($c -is [Windows.Controls.CheckBox]) { $c.IsChecked = [bool]$Value }
    elseif ($c -is [Windows.Controls.ComboBox]) {
        foreach ($i in $c.Items) {
            if (($i -is [Windows.Controls.ComboBoxItem] -and [string]$i.Tag -eq [string]$Value) -or ([string]$i -eq [string]$Value)) { $c.SelectedItem = $i; return }
        }
        if ($c.IsEditable) { $c.Text = [string]$Value }
    }
}

function Open-Thing {
    param([string]$Target, [string]$ArgList = '')
    try {
        if ($ArgList) { Start-Process -FilePath $Target -ArgumentList $ArgList -ErrorAction Stop } else { Start-Process -FilePath $Target -ErrorAction Stop }
        Say "  Opened $Target $ArgList" 'dim'
    } catch { Say "  Could not open $Target : $($_.Exception.Message)" 'fail' }
}

# ---- header chips -----------------------------------------------------------------------
function New-Chip {
    param([string]$Text, [string]$Fg = '#C9D3DF', [string]$Bg = '#161D26', [string]$Key = '')
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = New-Object Windows.CornerRadius(12)
    $b.Padding = Get-Thick 11 4 11 4
    $b.Margin = Get-Thick 8 0 0 0
    $b.Background = Get-Brush $Bg
    $b.BorderBrush = Get-Brush '#262E3A'; $b.BorderThickness = Get-Thick 1
    $t = New-Text $Text 12 $Fg 'SemiBold'
    $b.Child = $t
    if ($Key) { $UI[$Key] = $b; $UI["$Key.text"] = $t }
    [void]$Ctl.ChipPanel.Children.Add($b)
    return $b
}

function Update-RebootChip {
    if ($sync.RebootNeeded -and $UI['chip.reboot']) { $UI['chip.reboot'].Visibility = 'Visible' }
}

function Update-Banner {
    $msgs = @()
    if (-not $Cfg.IsAdmin) { $msgs += 'Read-only mode: not running as Administrator, so changes are disabled.' }
    $g = Get-RenameGuard
    if ($g.Blocked -and $g.Short -eq 'protected PC') { $msgs += "PROTECTED MACHINE - this PC will never be renamed ($($g.Reason))." }
    elseif ($g.Blocked -and $g.Short -eq 'no registry') { $msgs += 'Renaming is off: launched from the internet with no name registry. Set one in Names & settings.' }
    if ($msgs.Count) { $Ctl.BannerText.Text = ($msgs -join '   '); $Ctl.Banner.Visibility = 'Visible' } else { $Ctl.Banner.Visibility = 'Collapsed' }
}


# ===========================================================================
#  PAGES - part 1: helpers, Dashboard, Quick setup, Apps, Windows Update, PC setup
# ===========================================================================

$AppCatalog = @(
    @{ C = 'Browsers'; N = 'Google Chrome'; I = 'Google.Chrome'; E = $true }
    @{ C = 'Browsers'; N = 'Mozilla Firefox'; I = 'Mozilla.Firefox' }
    @{ C = 'Browsers'; N = 'Brave'; I = 'Brave.Brave' }
    @{ C = 'Browsers'; N = 'Opera'; I = 'Opera.Opera' }
    @{ C = 'Office and PDF'; N = 'Adobe Acrobat Reader'; I = 'Adobe.Acrobat.Reader.64-bit'; E = $true }
    @{ C = 'Office and PDF'; N = 'Microsoft 365 (Office)'; I = 'Microsoft.Office'; T = 'Word, Excel, PowerPoint, Outlook. Activate by signing in with the licensed account.' }
    @{ C = 'Office and PDF'; N = 'LibreOffice'; I = 'TheDocumentFoundation.LibreOffice' }
    @{ C = 'Office and PDF'; N = 'Foxit PDF Reader'; I = 'Foxit.FoxitReader' }
    @{ C = 'Office and PDF'; N = 'SumatraPDF'; I = 'SumatraPDF.SumatraPDF' }
    @{ C = 'Office and PDF'; N = 'Notepad++'; I = 'Notepad++.Notepad++' }
    @{ C = 'Office and PDF'; N = 'Adobe Creative Cloud'; I = 'Adobe.CreativeCloud' }
    @{ C = 'Files and cloud'; N = '7-Zip'; I = '7zip.7zip'; E = $true }
    @{ C = 'Files and cloud'; N = 'WinRAR'; I = 'RARLab.WinRAR' }
    @{ C = 'Files and cloud'; N = 'Everything (file search)'; I = 'voidtools.Everything' }
    @{ C = 'Files and cloud'; N = 'Google Drive'; I = 'Google.GoogleDrive' }
    @{ C = 'Files and cloud'; N = 'Dropbox'; I = 'Dropbox.Dropbox' }
    @{ C = 'Media'; N = 'VLC media player'; I = 'VideoLAN.VLC'; E = $true }
    @{ C = 'Media'; N = 'K-Lite Codec Pack'; I = 'CodecGuide.K-LiteCodecPack.Standard' }
    @{ C = 'Media'; N = 'ShareX (screenshots)'; I = 'ShareX.ShareX' }
    @{ C = 'Media'; N = 'Greenshot'; I = 'Greenshot.Greenshot' }
    @{ C = 'Chat and meetings'; N = 'WhatsApp'; I = '9NKSQGP7F2NH'; S = 'msstore'; T = 'From the Microsoft Store source.' }
    @{ C = 'Chat and meetings'; N = 'Zoom'; I = 'Zoom.Zoom' }
    @{ C = 'Chat and meetings'; N = 'Microsoft Teams'; I = 'Microsoft.Teams' }
    @{ C = 'Chat and meetings'; N = 'Telegram'; I = 'Telegram.TelegramDesktop' }
    @{ C = 'Remote support'; N = 'AnyDesk'; I = 'AnyDeskSoftwareGmbH.AnyDesk'; E = $true }
    @{ C = 'Remote support'; N = 'RustDesk'; I = 'RustDesk.RustDesk' }
    @{ C = 'Remote support'; N = 'TeamViewer'; I = 'TeamViewer.TeamViewer' }
    @{ C = 'Runtimes'; N = 'Visual C++ 2015-2022'; I = 'Microsoft.VCRedist.2015+.x64,Microsoft.VCRedist.2015+.x86'; E = $true; T = 'x64 and x86. Needed by most games and engineering apps.' }
    @{ C = 'Runtimes'; N = 'Visual C++ 2010-2013'; I = 'Microsoft.VCRedist.2013.x64,Microsoft.VCRedist.2013.x86,Microsoft.VCRedist.2012.x64,Microsoft.VCRedist.2012.x86,Microsoft.VCRedist.2010.x64,Microsoft.VCRedist.2010.x86'; T = 'For older software.' }
    @{ C = 'Runtimes'; N = '.NET Desktop Runtime 8'; I = 'Microsoft.DotNet.DesktopRuntime.8'; E = $true }
    @{ C = 'Runtimes'; N = 'Java Runtime (JRE)'; I = 'Oracle.JavaRuntimeEnvironment' }
    @{ C = 'Runtimes'; N = 'DirectX runtime'; I = 'Microsoft.DirectX' }
    @{ C = 'Runtimes'; N = 'Edge WebView2 Runtime'; I = 'Microsoft.EdgeWebView2Runtime' }
    @{ C = 'IT tools'; N = 'Advanced IP Scanner'; I = 'Famatech.AdvancedIPScanner' }
    @{ C = 'IT tools'; N = 'Angry IP Scanner'; I = 'angryziber.AngryIPScanner' }
    @{ C = 'IT tools'; N = 'PuTTY'; I = 'PuTTY.PuTTY' }
    @{ C = 'IT tools'; N = 'WinSCP'; I = 'WinSCP.WinSCP' }
    @{ C = 'IT tools'; N = 'CrystalDiskInfo'; I = 'CrystalDewWorld.CrystalDiskInfo' }
    @{ C = 'IT tools'; N = 'CPU-Z'; I = 'CPUID.CPU-Z' }
    @{ C = 'IT tools'; N = 'HWiNFO'; I = 'REALiX.HWiNFO' }
    @{ C = 'IT tools'; N = 'TreeSize Free'; I = 'JAMSoftware.TreeSize.Free' }
    @{ C = 'IT tools'; N = 'Rufus (bootable USB)'; I = 'Rufus.Rufus' }
    @{ C = 'IT tools'; N = 'PowerToys'; I = 'Microsoft.PowerToys' }
    @{ C = 'IT tools'; N = 'Windows Terminal'; I = 'Microsoft.WindowsTerminal' }
    @{ C = 'IT tools'; N = 'PowerShell 7'; I = 'Microsoft.PowerShell' }
    @{ C = 'IT tools'; N = 'Wireshark'; I = 'WiresharkFoundation.Wireshark' }
    @{ C = 'IT tools'; N = 'Visual Studio Code'; I = 'Microsoft.VisualStudioCode' }
    @{ C = 'IT tools'; N = 'Git'; I = 'Git.Git' }
    @{ C = 'Security'; N = 'Malwarebytes'; I = 'Malwarebytes.Malwarebytes' }
)
# Your own additions: tqny-apps.csv next to the tool, columns Category,Name,Id,Source
$extraApps = Join-Path $Cfg.ScriptDir 'tqny-apps.csv'
if (Test-Path -LiteralPath $extraApps) {
    try {
        foreach ($r in (Import-Csv -LiteralPath $extraApps)) {
            if ($r.Name -and $r.Id) { $AppCatalog += @{ C = $(if ($r.Category) { $r.Category } else { 'My apps' }); N = $r.Name; I = $r.Id; S = $r.Source } }
        }
    } catch { }
}

function Get-SelectedApps {
    $list = @()
    for ($i = 0; $i -lt $AppCatalog.Count; $i++) {
        if ($UI["app.$i"] -and $UI["app.$i"].IsChecked) { $a = $AppCatalog[$i]; $list += @{ Name = $a.N; Id = $a.I; Src = $a.S } }
    }
    return $list
}

function Get-TimeZonePairs { Get-TimeZone -ListAvailable | ForEach-Object { , @($_.DisplayName, $_.Id) } }

function Get-UsbBackupRoot {
    $usb = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction SilentlyContinue | Where-Object { $_.FreeSpace -gt 0 } | Select-Object -First 1
    if (-not $usb) {
        $usb = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object { $_.DeviceID -ne $env:SystemDrive } | Sort-Object FreeSpace -Descending | Select-Object -First 1
    }
    $root = if ($usb) { $usb.DeviceID + '\' } else { $env:SystemDrive + '\' }
    return (Join-Path $root ("TQNY-Backup\{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd')))
}

function Test-AdminUI {
    param([string]$What)
    if ($Cfg.IsAdmin) { return $true }
    Say "  '$What' needs Administrator." 'fail'
    Show-Msg "'$What' needs Administrator rights.`n`nClose TQNY IT Setup and start it again, then choose Yes at the Administrator prompt." 'Warning'
    return $false
}

function Request-Restart {
    param([string]$Why = 'Some changes need a restart to finish.')
    $State.RebootAsked = $true
    if (Confirm-UI "$Why`n`nRestart the PC now?") {
        Start-Process shutdown.exe -ArgumentList '/r /t 5 /c "TQNY-Setup: restarting to finish the changes"'
        Say '  Restarting in 5 seconds...' 'warn'
    }
}

# ===========================================================================
#  Dashboard
# ===========================================================================
Add-NavGroup 'Setup'
$pg = Add-Page 'home' 'Dashboard' 'This PC at a glance. Everything here is read-only.' 'E80F'

$dashWrap = New-Object Windows.Controls.WrapPanel
$dashWrap.Margin = Get-Thick 0 0 0 4
[void]$pg.Children.Add($dashWrap)
foreach ($d in @(@('Computer', 'Computer'), @('Model', 'Model'), @('Windows', 'Windows'), @('Activation', 'Activation'), @('Cpu', 'Processor'),
        @('Memory', 'Memory'), @('Storage', 'Storage'), @('Network', 'Network'), @('Internet', 'Internet'), @('Security', 'Security'),
        @('Drivers', 'Drivers'), @('Firmware', 'Firmware'), @('Uptime', 'Uptime'))) {
    $b = New-Object Windows.Controls.Border
    $b.Width = 250; $b.Height = 96; $b.CornerRadius = New-Object Windows.CornerRadius(10)
    $b.Background = Get-Brush '#151A21'; $b.BorderBrush = Get-Brush '#232B37'; $b.BorderThickness = Get-Thick 1
    $b.Margin = Get-Thick 0 0 12 12; $b.Padding = Get-Thick 16 12 14 10
    $sp = New-Object Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $d[1].ToUpper() 10.5 '#6F7B8B' 'SemiBold'))
    $v = New-Text '...' 17 '#FFFFFF' 'SemiBold'; $v.Margin = Get-Thick 0 6 0 0; $v.TextTrimming = 'CharacterEllipsis'
    $s = New-Text '' 11.5 '#8B98A9'; $s.Margin = Get-Thick 0 3 0 0; $s.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($v); [void]$sp.Children.Add($s)
    $b.Child = $sp
    $UI["dash.$($d[0])"] = $v; $UI["dash.$($d[0]).sub"] = $s
    [void]$dashWrap.Children.Add($b)
}

function Set-Dashboard {
    param($d)
    if (-not $d) { return }
    foreach ($k in 'Computer', 'Model', 'Windows', 'Activation', 'Cpu', 'Memory', 'Storage', 'Network', 'Internet', 'Security', 'Drivers', 'Firmware', 'Uptime') {
        $UI["dash.$k"].Text = [string]$d[$k]
        $UI["dash.$k"].ToolTip = [string]$d[$k]
        $UI["dash.$k.sub"].Text = [string]$d["$($k)Sub"]
        $UI["dash.$k.sub"].ToolTip = [string]$d["$($k)Sub"]
        $UI["dash.$k"].Foreground = Get-Brush '#FFFFFF'
    }
    if ($d.Activation -ne 'Activated') { $UI['dash.Activation'].Foreground = $Brush.warn }
    if ($d.Internet -ne 'Online') { $UI['dash.Internet'].Foreground = $Brush.fail } else { $UI['dash.Internet'].Foreground = $Brush.ok }
    if ($d.StorageLow) { $UI['dash.Storage'].Foreground = $Brush.warn }
    if ($d.Drivers -ne 'All working') { $UI['dash.Drivers'].Foreground = $Brush.warn }
    if ($d.Security -match 'OFF|No antivirus') { $UI['dash.Security'].Foreground = $Brush.fail }
    if ($d.UptimeSub -eq 'Restart pending') { $UI['dash.Uptime.sub'].Foreground = $Brush.warn }
}

function Update-Dashboard {
    [void](Start-Task 'Reading this PC' { Get-DashboardData } -Silent -OnDone { param($r) Set-Dashboard $r; Say '  Dashboard updated.' 'dim' })
}

$c = Add-Card $pg 'Quick actions'
Add-Tiles $c @(
    @{ T = 'Quick setup'; S = 'The post-format checklist'; V = 'primary'; A = { Show-Page 'quick' } }
    @{ T = 'Refresh'; S = 'Read this PC again'; A = { Update-Dashboard } }
    @{ T = 'Health check'; S = 'Disk, updates, antivirus, BitLocker'; A = { [void](Start-Task 'Health check' { Invoke-HealthCheck }) } }
    @{ T = 'Check the internet'; S = 'Adapter, gateway, DNS, web'; A = { [void](Start-Task 'Internet check' { [void](Test-Internet) }) } }
    @{ T = 'System information'; S = 'Full specification'; A = { [void](Start-Task 'System information' { Show-SystemSpec }) } }
    @{ T = 'Handover sheet'; S = 'Printable report for the customer'; A = { Show-Page 'reports' } }
    @{ T = 'Back up before format'; S = 'Files, Wi-Fi, drivers, apps, printers'; A = { Show-Page 'backup' } }
)

# ===========================================================================
#  Quick setup
# ===========================================================================
$pg = Add-Page 'quick' 'Quick setup' 'Tick what this PC needs after a fresh Windows install, then run it all in one go. Each step logs what it did.' 'E945'

$c = Add-Card $pg 'Post-format checklist' 'Steps run in the order shown. A failed step does not stop the others; the summary at the end shows what needs a second look.'
$QuickSteps = @(
    @('restore', 'Restore a backup first (files, Wi-Fi, printers)', $false),
    @('rename', 'Rename this PC (registry-checked)', $false),
    @('tz', 'Set the time zone and sync the clock', $true),
    @('power', 'Never sleep on mains power', $true),
    @('network', 'Make visible on the network (Private + sharing)', $true),
    @('ping', 'Allow ping on the local network', $true),
    @('rdp', 'Enable Remote Desktop', $false),
    @('explorer', 'Show file extensions + desktop icons', $true),
    @('faststartup', 'Turn off Fast Startup', $false),
    @('arabic', 'Add the Arabic keyboard', $false),
    @('netfx3', 'Enable .NET Framework 3.5', $false),
    @('bloat', 'Remove built-in junk apps', $false),
    @('share', 'Create the shared folder', $false),
    @('apps', 'Install the apps ticked on the Apps page', $true),
    @('activate', 'Activate Windows with a key', $false),
    @('updates', 'Install all Windows updates', $true),
    @('drivers', 'Install driver updates from Windows Update', $true),
    @('cleanup', 'Clean temp files', $true),
    @('restorepoint', 'Create a restore point', $true),
    @('handover', 'Write the handover sheet', $true)
)
$checks = foreach ($q in $QuickSteps) { New-Check "qs.$($q[0])" $q[1] $q[2] -Wd 330 }
Add-Checks $c $checks

Add-SubHead $c 'Options for the steps above'
Add-Fields $c @(
    @{ L = 'Time zone'; C = (New-Combo 'qs.tzval' -Wd 330) }
    @{ L = 'New name (blank = next free number)'; C = (New-Input 'qs.name' '' 230 'Leave empty to take the next free PREFIX-NN number.') }
    @{ L = 'Windows key, or OEM for the BIOS key'; C = (New-Input 'qs.key' '' 300) }
)
Add-Fields $c @(
    @{ L = 'Shared folder path'; C = (New-Input 'qs.sharepath' 'C:\TQNY-Share' 230) }
    @{ L = 'Share name'; C = (New-Input 'qs.sharename' 'TQNY-Share' 160) }
    @{ L = 'Restore from backup folder'; C = (New-Input 'qs.restorefrom' '' 330) }
)
Add-Note $c 'The handover sheet uses the customer details on the Reports page. Apps come from the Apps page.' -Key 'qs.appsnote'
Add-Tiles $c @(
    @{ T = 'Run selected steps'; S = 'Confirms first, then runs in the background'; V = 'primary'; A = { Start-QuickSetup } }
    @{ T = 'Choose apps'; S = 'Open the Apps page'; A = { Show-Page 'apps' } }
    @{ T = 'Pick the backup folder'; S = 'For "Restore a backup first"'; A = { $f = Select-Folder 'Choose the TQNY-Backup folder of this PC'; if ($f) { Set-V 'qs.restorefrom' $f; $UI['qs.restore'].IsChecked = $true } } }
)

$c = Add-Card $pg 'Presets' 'Save the ticks, options and app choices as a preset - for example "Office PC" or "Reception" - and load it on the next PC.'
Add-Fields $c @(
    @{ L = 'Saved presets'; C = (New-Combo 'qs.preset' -Wd 240) }
    @{ L = 'Save as'; C = (New-Input 'qs.presetname' '' 200) }
)
Add-Tiles $c @(
    @{ T = 'Load preset'; S = 'Apply the saved ticks'; A = { Import-QuickPreset (Get-V 'qs.preset') } }
    @{ T = 'Save preset'; S = 'Store the current ticks'; A = { Export-QuickPreset (Get-V 'qs.presetname') } }
    @{ T = 'Delete preset'; S = 'Remove the selected one'; V = 'danger'; A = { Remove-QuickPreset (Get-V 'qs.preset') } }
)

function Get-PresetDir { Join-Path $Cfg.DataDir 'presets' }
function Update-PresetList {
    $names = @(Get-ChildItem -LiteralPath (Get-PresetDir) -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object)
    Set-ComboItems $UI['qs.preset'] $names
}
function Export-QuickPreset {
    param([string]$Name)
    if (-not $Name) { Show-Msg 'Type a name for the preset first.' 'Warning'; return }
    $Name = $Name -replace '[\\/:*?"<>|]', '_'
    $o = [ordered]@{
        Steps = @($QuickSteps | Where-Object { $UI["qs.$($_[0])"].IsChecked } | ForEach-Object { $_[0] })
        TimeZone = Get-V 'qs.tzval'; SharePath = Get-V 'qs.sharepath'; ShareName = Get-V 'qs.sharename'
        Apps = @(Get-SelectedApps | ForEach-Object { $_.Id })
    }
    New-Item -ItemType Directory -Path (Get-PresetDir) -Force | Out-Null
    $o | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Get-PresetDir) "$Name.json") -Encoding UTF8
    Update-PresetList; Set-V 'qs.preset' $Name
    Say "  Preset '$Name' saved." 'ok'
}
function Import-QuickPreset {
    param([string]$Name)
    $f = Join-Path (Get-PresetDir) "$Name.json"
    if (-not $Name -or -not (Test-Path -LiteralPath $f)) { Show-Msg 'Pick a saved preset first.' 'Warning'; return }
    $o = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    foreach ($q in $QuickSteps) { $UI["qs.$($q[0])"].IsChecked = (@($o.Steps) -contains $q[0]) }
    if ($o.TimeZone) { Set-V 'qs.tzval' $o.TimeZone }
    if ($o.SharePath) { Set-V 'qs.sharepath' $o.SharePath }
    if ($o.ShareName) { Set-V 'qs.sharename' $o.ShareName }
    for ($i = 0; $i -lt $AppCatalog.Count; $i++) { if ($UI["app.$i"]) { $UI["app.$i"].IsChecked = (@($o.Apps) -contains $AppCatalog[$i].I) } }
    Update-QuickAppsNote
    Say "  Preset '$Name' loaded." 'ok'
}
function Remove-QuickPreset {
    param([string]$Name)
    if (-not $Name) { return }
    if (-not (Confirm-UI "Delete the preset '$Name'?")) { return }
    Remove-Item -LiteralPath (Join-Path (Get-PresetDir) "$Name.json") -Force -ErrorAction SilentlyContinue
    Update-PresetList
    Say "  Preset '$Name' deleted." 'warn'
}
function Update-QuickAppsNote {
    $n = @(Get-SelectedApps).Count
    $UI['qs.apps'].Content = "Install the $n app(s) ticked on the Apps page"
}

function Start-QuickSetup {
    $steps = @($QuickSteps | Where-Object { $UI["qs.$($_[0])"].IsChecked } | ForEach-Object { $_[0] })
    if ($steps.Count -eq 0) { Show-Msg 'Tick at least one step.' 'Warning'; return }
    $p = @{
        Steps = $steps; TimeZone = Get-V 'qs.tzval'; CustomName = Get-V 'qs.name'; WinKey = Get-V 'qs.key'
        SharePath = Get-V 'qs.sharepath'; ShareName = Get-V 'qs.sharename'; RestoreFrom = Get-V 'qs.restorefrom'
        Apps = @(Get-SelectedApps); Customer = Get-V 'ho.customer'; Contact = Get-V 'ho.contact'; Notes = Get-V 'ho.notes'
    }
    if ($steps -contains 'rename' -and $p.CustomName) {
        $bad = Test-ComputerName $p.CustomName
        if ($bad) { Show-Msg $bad 'Warning'; return }
    }
    if ($steps -contains 'restore' -and (-not $p.RestoreFrom -or -not (Test-Path -LiteralPath $p.RestoreFrom))) { Show-Msg 'Pick the backup folder for "Restore a backup first".' 'Warning'; return }
    if ($steps -contains 'activate' -and -not $p.WinKey) { Show-Msg 'Type the Windows key (or OEM) for "Activate Windows".' 'Warning'; return }
    if ($steps -contains 'share' -and (-not $p.SharePath -or -not $p.ShareName)) { Show-Msg 'Fill in the shared folder path and name.' 'Warning'; return }
    $labels = @($QuickSteps | Where-Object { $steps -contains $_[0] } | ForEach-Object { '  - ' + $_[1] })
    if ($steps -contains 'apps') { $labels += "      ($($p.Apps.Count) app(s) ticked)" }
    if (-not (Confirm-UI "Run these $($steps.Count) step(s) on $($Facts.Name)?" ($labels -join "`n"))) { return }
    [void](Start-Task 'Quick setup' { Invoke-QuickSetup $P } -Params $p -Admin -OnDone {
        param($r, $p)
        if ($sync.RebootNeeded) { Request-Restart 'Quick setup finished. The rename and/or updates need a restart.' }
    })
}

$PageInit['quick'] = {
    Set-ComboPairs $UI['qs.tzval'] @(Get-TimeZonePairs) $Cfg.TZ
    Update-PresetList
    $g = Get-RenameGuard
    if ($g.Blocked) { $UI['qs.rename'].IsChecked = $false; $UI['qs.rename'].IsEnabled = $false; $UI['qs.rename'].Content = "Rename this PC - blocked: $($g.Short)" }
}
$PageShow['quick'] = { Update-QuickAppsNote }

# ===========================================================================
#  Apps
# ===========================================================================
$pg = Add-Page 'apps' 'Apps' 'Install software silently with winget - the Windows package manager. Downloads come straight from each vendor.' 'E71D'

$c = Add-Card $pg 'Package manager'
Add-Note $c 'Checking winget...' -Key 'apps.wgstatus'
Add-Tiles $c @(
    @{ T = 'Install / repair winget'; S = 'Fresh Windows 10 often lacks it'; A = { [void](Start-Task 'Install winget' { Install-Winget } -Admin -OnDone { Update-WingetStatus }) } }
    @{ T = 'Update all apps'; S = 'winget upgrade --all'; A = { if (Confirm-UI 'Update every app winget knows about?') { [void](Start-Task 'Update all apps' { Invoke-WingetCommand 'upgrade' } -Admin) } } }
    @{ T = 'Show available updates'; S = 'Read only'; A = { [void](Start-Task 'Available app updates' { Invoke-WingetCommand 'list-upgrades' }) } }
)

$c = Add-Card $pg 'Choose apps' 'Tick what this PC needs. Hover over an app to see its winget ID.'
$cats = @($AppCatalog | ForEach-Object { $_.C } | Select-Object -Unique)
foreach ($cat in $cats) {
    Add-SubHead $c $cat
    $list = @()
    for ($i = 0; $i -lt $AppCatalog.Count; $i++) {
        $a = $AppCatalog[$i]
        if ($a.C -ne $cat) { continue }
        $tip = "winget id: $($a.I)"; if ($a.T) { $tip = "$($a.T)`n$tip" }
        $list += New-Check "app.$i" $a.N $false $tip 230
    }
    Add-Checks $c $list
}
Add-Tiles $c @(
    @{ T = 'Install ticked apps'; S = 'Silent install, one after another'; V = 'primary'; A = {
            $apps = @(Get-SelectedApps)
            if ($apps.Count -eq 0) { Show-Msg 'Tick at least one app.' 'Warning'; return }
            if (-not (Confirm-UI "Install $($apps.Count) app(s)?" (($apps | ForEach-Object { '  - ' + $_.Name }) -join "`n"))) { return }
            [void](Start-Task 'Install apps' { Install-WingetApps $P.Apps } -Params @{ Apps = $apps } -Admin)
        } }
    @{ T = 'Tick the essentials'; S = 'Chrome, 7-Zip, Reader, VLC, AnyDesk, runtimes'; A = { for ($i = 0; $i -lt $AppCatalog.Count; $i++) { if ($AppCatalog[$i].E) { $UI["app.$i"].IsChecked = $true } }; Say '  Essentials ticked.' 'dim' } }
    @{ T = 'Clear all ticks'; S = ''; A = { for ($i = 0; $i -lt $AppCatalog.Count; $i++) { $UI["app.$i"].IsChecked = $false } } }
)
Add-Note $c 'Add your own apps: create tqny-apps.csv next to the tool with the columns Category,Name,Id,Source.'

$c = Add-Card $pg 'Anything else'
Add-Fields $c @(
    @{ L = 'Search winget for'; C = (New-Input 'apps.search' '' 220) }
    @{ L = 'Install by winget ID'; C = (New-Input 'apps.id' '' 260 'For example Microsoft.Skype or 9WZDNCRFJ3PS (Store ID)') }
)
Add-Tiles $c @(
    @{ T = 'Search'; S = 'Find the ID of an app'; A = { $q = Get-V 'apps.search'; if (-not $q) { Show-Msg 'Type something to search for.' 'Warning'; return }; [void](Start-Task "Search $q" { Invoke-WingetCommand 'search' $P.Q } -Params @{ Q = $q }) } }
    @{ T = 'Install this ID'; S = 'Exact winget ID'; A = {
            $id = Get-V 'apps.id'; if (-not $id) { Show-Msg 'Type a winget ID.' 'Warning'; return }
            $src = if ($id -match '^[0-9A-Z]{12}$') { 'msstore' } else { $null }
            [void](Start-Task "Install $id" { Install-WingetApps @(@{ Name = $P.Id; Id = $P.Id; Src = $P.Src }) } -Params @{ Id = $id; Src = $src } -Admin)
        } }
)

$c = Add-Card $pg 'Move apps to a new PC' 'Save the app list on the old PC, then install the same apps on the new one in one go.'
Add-Tiles $c @(
    @{ T = 'Save app list'; S = 'winget export to a .json file'; A = {
            $f = Select-File 'App list (*.json)|*.json' -Save -Name "apps-$($Facts.Name).json"
            if ($f) { [void](Start-Task 'Save app list' { Invoke-WingetCommand 'export' $P.F } -Params @{ F = $f }) }
        } }
    @{ T = 'Install from app list'; S = 'winget import a .json file'; A = {
            $f = Select-File 'App list (*.json)|*.json'
            if ($f -and (Confirm-UI "Install every app listed in $(Split-Path $f -Leaf)?")) { [void](Start-Task 'Install from app list' { Invoke-WingetCommand 'import' $P.F } -Params @{ F = $f } -Admin) }
        } }
    @{ T = 'Installed programs to CSV'; S = 'Everything in Apps & features'; A = {
            $f = Select-File 'CSV (*.csv)|*.csv' -Save -Name "programs-$($Facts.Name).csv"
            if ($f) { [void](Start-Task 'Installed programs' { [void](Export-InstalledPrograms $P.F) } -Params @{ F = $f }) }
        } }
)

$c = Add-Card $pg 'Offline installers' 'Point at a folder of .msi / .exe installers (for example on your USB). MSI files install silently; EXE files open one after another for you to finish.'
Add-Fields $c @(@{ L = 'Installers folder'; C = (New-Input 'apps.folder' (Join-Path $Cfg.ScriptDir 'installers') 420) })
Add-Tiles $c @(
    @{ T = 'Browse...'; S = 'Pick the folder'; A = { $f = Select-Folder 'Folder with .msi / .exe installers' (Get-V 'apps.folder'); if ($f) { Set-V 'apps.folder' $f } } }
    @{ T = 'Install all from folder'; S = 'In name order'; V = 'primary'; A = {
            $f = Get-V 'apps.folder'
            if (-not $f -or -not (Test-Path -LiteralPath $f)) { Show-Msg 'That folder does not exist.' 'Warning'; return }
            if (Confirm-UI "Run every installer in $f ?") { [void](Start-Task 'Offline installers' { Install-LocalInstallers $P.F } -Params @{ F = $f } -Admin) }
        } }
)

$c = Add-Card $pg 'Clean out Windows extras'
Add-Tiles $c @(
    @{ T = 'Remove built-in junk apps'; S = 'Candy Crush, news, Xbox overlay...'; V = 'danger'; A = {
            if (Confirm-UI 'Remove the common pre-installed junk apps for every user?' 'Keeps Store, Photos, Calculator, Notepad, Paint, Snipping Tool, Media Player, Outlook, Quick Assist and Phone Link.' -Danger) {
                [void](Start-Task 'Remove junk apps' { Remove-Bloatware } -Admin)
            }
        } }
    @{ T = 'Open Installed apps'; S = 'Uninstall by hand'; A = { Open-Thing 'ms-settings:appsfeatures' } }
    @{ T = 'Programs and Features'; S = 'Classic uninstall list'; A = { Open-Thing 'appwiz.cpl' } }
)

function Update-WingetStatus {
    $v = Get-WingetVersion
    if ($v) { $UI['apps.wgstatus'].Text = "winget $v is ready."; $UI['apps.wgstatus'].Foreground = $Brush.ok }
    else { $UI['apps.wgstatus'].Text = 'winget is NOT installed on this PC. Click "Install / repair winget" first.'; $UI['apps.wgstatus'].Foreground = $Brush.warn }
}
$PageInit['apps'] = { Update-WingetStatus }

# ===========================================================================
#  Windows Update
# ===========================================================================
$pg = Add-Page 'updates' 'Windows Update' 'Check and install updates from inside the tool, using the Windows Update service itself - no extra modules.' 'E895'

$c = Add-Card $pg 'Updates'
Add-Checks $c @((New-Check 'wu.mu' 'Also update Office and other Microsoft products (turns on Microsoft Update)' $false))
Add-Tiles $c @(
    @{ T = 'Check for updates'; S = 'Read only - lists what is waiting'; A = { [void](Start-Task 'Check for updates' { Show-WindowsUpdates -Kind 'All' -MicrosoftUpdate $P.MU } -Params @{ MU = (Get-V 'wu.mu') } -Admin) } }
    @{ T = 'Install all updates'; S = 'Downloads and installs, one by one'; V = 'primary'; A = {
            if (Confirm-UI 'Install every available Windows update?' 'This can take a long time on a fresh install. The PC stays usable; you will be asked to restart at the end.') {
                [void](Start-Task 'Windows Update' { Install-WindowsUpdates -Kind 'Software' -MicrosoftUpdate $P.MU } -Params @{ MU = (Get-V 'wu.mu') } -Admin -OnDone { if ($sync.RebootNeeded) { Request-Restart 'Updates were installed and need a restart.' } })
            }
        } }
    @{ T = 'Drivers from Windows Update'; S = 'Install every offered driver'; A = {
            if (Confirm-UI 'Install every driver Windows Update offers for this PC?') { [void](Start-Task 'Driver updates' { Install-WindowsUpdates -Kind 'Driver' } -Admin) }
        } }
    @{ T = 'Update history'; S = 'Last 30 installs'; A = { [void](Start-Task 'Update history' { Show-UpdateHistory }) } }
    @{ T = 'Open Windows Update'; S = 'The Settings page'; A = { Open-Thing 'ms-settings:windowsupdate' } }
)

$c = Add-Card $pg 'Control Windows Update'
Add-Tiles $c @(
    @{ T = 'Pause for 7 days'; S = 'Stickier than turning it off'; A = { [void](Start-Task 'Pause updates' { Set-WindowsUpdateMode 'pause' } -Admin) } }
    @{ T = 'Turn on / resume'; S = 'Service on, pause removed'; A = { [void](Start-Task 'Resume updates' { Set-WindowsUpdateMode 'on' } -Admin) } }
    @{ T = 'Turn off'; S = 'Stop and disable the service'; V = 'danger'; A = { if (Confirm-UI 'Turn Windows Update OFF?' 'Windows often turns it back on by itself. Pausing is more reliable.' -Danger) { [void](Start-Task 'Turn off updates' { Set-WindowsUpdateMode 'off' } -Admin) } } }
    @{ T = 'Reset Windows Update'; S = 'Fix stuck / failing updates'; A = { if (Confirm-UI 'Reset the Windows Update components?' 'Stops the update services, renames the update cache folders and starts them again. Safe; Windows rebuilds the cache.') { [void](Start-Task 'Reset Windows Update' { Reset-WindowsUpdate } -Admin) } } }
)

$c = Add-Card $pg 'Microsoft Store apps'
Add-Tiles $c @(
    @{ T = 'Store updates'; S = 'Open Store downloads and updates'; A = { Open-Thing 'ms-windows-store://downloadsandupdates' } }
    @{ T = 'Update all apps (winget)'; S = 'Desktop apps too'; A = { if (Confirm-UI 'Update every app winget knows about?') { [void](Start-Task 'Update all apps' { Invoke-WingetCommand 'upgrade' } -Admin) } } }
)

# ===========================================================================
#  PC setup
# ===========================================================================
$pg = Add-Page 'pcsetup' 'PC setup' 'Name, time, power, Explorer, users and Windows features - the repetitive jobs on every new office PC.' 'E977'

$c = Add-Card $pg 'Computer name' 'Numbered names (PREFIX-01, -02...) are checked against the name registry AND the live network, so two PCs never get the same name.'
Add-Note $c '' '#C9D3DF' 'ren.status'
Add-Fields $c @(
    @{ L = 'How'; C = (New-Combo 'ren.mode' -Wd 200) }
    @{ L = 'Name (when typing one)'; C = (New-Input 'ren.name' '' 180 '1-15 letters, digits or hyphens. Not all digits.') }
    @{ L = 'Force number (optional)'; C = (New-Input 'ren.num' '' 120 'Leave empty to take the next free number.') }
    @{ L = 'Site code'; C = (New-Input 'ren.site' $(if ($Cfg.Site -ne '-') { $Cfg.Site } else { '' }) 110) }
)
Set-ComboPairs $UI['ren.mode'] @(@('Next free number', 'next'), @('Type a name', 'custom')) 'next'
Add-Checks $c @((New-Check 'ren.domain' 'Domain PC - rename with domain credentials' $false 'Only for domain-joined PCs. You will be asked for a domain account allowed to rename computers.'))
Add-Tiles $c @(
    @{ T = 'Preview'; S = 'Shows the name it would get. Changes nothing.'; A = { Start-RenameFlow $false } }
    @{ T = 'Rename this PC'; S = 'Previews, asks, then renames'; V = 'primary'; A = { Start-RenameFlow $true } }
)
Add-Fields $c @(@{ L = 'Computer description (shown next to the name on the network)'; C = (New-Input 'pc.desc' $(if ($Facts.Desc -ne '(not set)') { $Facts.Desc } else { '' }) 380) })
Add-Tiles $c @(@{ T = 'Set description'; S = 'Not the computer name'; A = { $d = Get-V 'pc.desc'; if (-not $d) { Show-Msg 'Type a description.' 'Warning'; return }; [void](Start-Task 'Computer description' { Set-ComputerDescription $P.D } -Params @{ D = $d } -Admin) } })

function Update-RenameStatus {
    $g = Get-RenameGuard
    $t = "This PC is $($Facts.Name).   Prefix: $($Cfg.Prefix)   Registry: $($Cfg.DbFile)"
    if ($g.Blocked) { $t += "`nRename blocked: $($g.Reason)"; $UI['ren.status'].Foreground = $Brush.warn } else { $UI['ren.status'].Foreground = Get-Brush '#C9D3DF' }
    $UI['ren.status'].Text = $t
}

function Start-RenameFlow {
    param([bool]$Apply)
    $mode = Get-V 'ren.mode'
    $custom = ''
    if ($mode -eq 'custom') {
        $custom = Get-V 'ren.name'
        if (-not $custom) { Show-Msg 'Type the new computer name.' 'Warning'; return }
        $bad = Test-ComputerName $custom
        if ($bad) { Show-Msg $bad 'Warning'; return }
    }
    $num = Get-V 'ren.num'
    if ($num -and $mode -eq 'next') {
        if ($num -notmatch '^\d+$' -or [int]$num -lt 1) { Show-Msg 'The forced number must be a whole number, 1 or higher.' 'Warning'; return }
        $num = [string][int]$num
    } else { $num = '' }
    $site = Get-V 'ren.site'
    if ($site) { $Cfg.Site = $site -replace ',', ' ' }
    $fd = [bool](Get-V 'ren.domain')
    if ($Apply -and -not (Test-AdminUI 'Rename this PC')) { return }
    $p = @{ Custom = $custom; Num = $num; FD = $fd; Apply = $Apply }
    [void](Start-Task $(if ($Apply) { 'Rename - checking the name' } else { 'Rename preview' }) { Invoke-NameAllocation -Apply $false -CustomName $P.Custom -ForceNum $P.Num -ForceDomain $P.FD } -Params $p -OnDone {
        param($r, $p)
        if (-not $p.Apply) { return }
        if (-not $r -or -not $r.Target) { Show-Msg 'No name could be allocated. See the log.' 'Warning'; return }
        if ($r.Blocked) { Show-Msg 'This PC is blocked from renaming. See the log for the reason.' 'Warning'; return }
        if ($r.Target -ieq $Facts.Name) { Show-Msg "This PC is already named $($r.Target)."; return }
        if (-not (Confirm-UI "Rename $($Facts.Name) to $($r.Target)?" 'The new name is recorded in the registry and takes effect after a restart.')) { Say '  Cancelled. Nothing was changed.' 'warn'; return }
        $cred = $null
        if ($p.FD) { $cred = Request-Cred 'Domain account allowed to rename this computer'; if (-not $cred) { Say '  Cancelled - no domain credentials.' 'warn'; return } }
        $p2 = @{ Custom = $p.Custom; Num = $p.Num; FD = $p.FD; Cred = $cred }
        [void](Start-Task 'Rename' {
                $a = Invoke-NameAllocation -Apply $true -CustomName $P.Custom -ForceNum $P.Num -ForceDomain $P.FD
                $ok = $false
                if ($a.Target) { $ok = Invoke-RenamePC -Target $a.Target -Cred $P.Cred -ForceDomain $P.FD }
                $ok
            } -Params $p2 -Admin -OnDone {
                param($ok)
                if ($ok) { Request-Restart "Renamed to $($sync.NewName). The new name becomes active after a restart." }
            })
    })
}
$PageShow['pcsetup'] = { Update-RenameStatus }

$c = Add-Card $pg 'Workgroup or domain'
Add-Fields $c @(
    @{ L = 'Workgroup'; C = (New-Input 'wg.name' $(if ($Facts.Workgroup) { $Facts.Workgroup } else { 'WORKGROUP' }) 170) }
    @{ L = 'Domain (e.g. company.local)'; C = (New-Input 'dom.name' '' 210) }
    @{ L = 'OU (optional)'; C = (New-Input 'dom.ou' '' 260 'OU=Computers,DC=company,DC=local') }
)
Add-Tiles $c @(
    @{ T = 'Join workgroup'; S = 'Same workgroup = easier sharing'; A = {
            $wg = Get-V 'wg.name'; if (-not $wg) { return }
            if (Confirm-UI "Put $($Facts.Name) in workgroup $wg ?" 'Takes effect after a restart.') { [void](Start-Task 'Join workgroup' { Set-Workgroup $P.N } -Params @{ N = $wg } -Admin) }
        } }
    @{ T = 'Join domain'; S = 'Asks for domain credentials'; A = {
            $d = Get-V 'dom.name'; if (-not $d) { Show-Msg 'Type the domain name.' 'Warning'; return }
            if (-not (Confirm-UI "Join $($Facts.Name) to the domain $d ?" 'You will be asked for a domain account that may join computers.')) { return }
            $cred = Request-Cred "Account allowed to join computers to $d"
            if (-not $cred) { return }
            [void](Start-Task 'Join domain' { Join-TqnyDomain -Domain $P.D -Cred $P.C -OU $P.O } -Params @{ D = $d; C = $cred; O = (Get-V 'dom.ou') } -Admin -OnDone { if ($sync.RebootNeeded) { Request-Restart 'Joined the domain.' } })
        } }
)

$c = Add-Card $pg 'Time and region'
Add-Fields $c @(
    @{ L = 'Time zone'; C = (New-Combo 'pc.tz' -Wd 380) }
    @{ L = 'Date / number format'; C = (New-Combo 'pc.culture' -Wd 220) }
)
Set-ComboPairs $UI['pc.culture'] @(@('English (United States)', 'en-US'), @('English (United Kingdom)', 'en-GB'), @('Arabic (Saudi Arabia)', 'ar-SA'), @('Arabic (UAE)', 'ar-AE')) 'en-US'
Add-Tiles $c @(
    @{ T = 'Set time zone and sync'; S = 'Then resync with the internet'; V = 'primary'; A = { [void](Start-Task 'Time zone' { Set-TimeZoneSync $P.Tz } -Params @{ Tz = (Get-V 'pc.tz') } -Admin) } }
    @{ T = 'Set date / number format'; S = 'For this user'; A = { [void](Start-Task 'Regional format' { Set-RegionFormat $P.C } -Params @{ C = (Get-V 'pc.culture') }) } }
    @{ T = 'Add Arabic keyboard'; S = 'Keeps English as default'; A = { [void](Start-Task 'Arabic keyboard' { Add-ArabicKeyboard } -Admin) } }
    @{ T = 'Repair the clock service'; S = 'When time keeps drifting'; A = { [void](Start-Task 'Repair time' { Invoke-Repair 'time' } -Admin) } }
)
$PageInit['pcsetup'] = { Set-ComboPairs $UI['pc.tz'] @(Get-TimeZonePairs) $Cfg.TZ }

$c = Add-Card $pg 'Power'
Add-Tiles $c @(
    @{ T = 'Never sleep'; S = 'Mains power; screen off after 15 min'; V = 'primary'; A = { [void](Start-Task 'Power - never sleep' { Set-PowerPlan @('never') } -Admin) } }
    @{ T = 'High performance plan'; S = 'Desktops'; A = { [void](Start-Task 'High performance' { Set-PowerPlan @('high') } -Admin) } }
    @{ T = 'Turn off Fast Startup'; S = 'Fixes shares and Wake-on-LAN'; A = { [void](Start-Task 'Fast Startup off' { Set-PowerPlan @('faststartup') } -Admin) } }
    @{ T = 'Turn off hibernation'; S = 'Frees GBs of disk'; A = { [void](Start-Task 'Hibernation off' { Set-PowerPlan @('hiberoff') } -Admin) } }
    @{ T = 'Lid does nothing'; S = 'Laptops on mains power'; A = { [void](Start-Task 'Lid action' { Set-PowerPlan @('lid') } -Admin) } }
    @{ T = 'Power options'; S = 'Open the control panel'; A = { Open-Thing 'powercfg.cpl' } }
)

$c = Add-Card $pg 'Explorer and desktop' 'Applies to the user running this tool.'
Add-Checks $c @(
    (New-Check 'ex.ext' 'Show file extensions' $true), (New-Check 'ex.hidden' 'Show hidden files' $false), (New-Check 'ex.thispc' 'Explorer opens This PC' $true),
    (New-Check 'ex.icons' 'This PC / Network / Control Panel on desktop' $true), (New-Check 'ex.classicmenu' 'Windows 11: full right-click menu' $false),
    (New-Check 'ex.taskleft' 'Windows 11: taskbar on the left' $false), (New-Check 'ex.searchicon' 'Taskbar search as an icon' $false))
Add-Tiles $c @(@{ T = 'Apply'; S = 'Explorer restarts briefly'; V = 'primary'; A = {
            $w = @(foreach ($k in 'ext', 'hidden', 'thispc', 'icons', 'classicmenu', 'taskleft', 'searchicon') { if (Get-V "ex.$k") { $k } })
            if ($w.Count -eq 0) { Show-Msg 'Tick at least one option.' 'Warning'; return }
            [void](Start-Task 'Explorer settings' { Set-ExplorerTweaks $P.W } -Params @{ W = $w })
        } })

$c = Add-Card $pg 'User accounts'
Add-Fields $c @(
    @{ L = 'User name'; C = (New-Input 'usr.name' '' 180) }
    @{ L = 'Password (blank = none)'; C = (New-Pass 'usr.pass' 180) }
)
Add-Checks $c @((New-Check 'usr.admin' 'Administrator' $false))
Add-Tiles $c @(
    @{ T = 'List users'; S = 'Who is admin, who is enabled'; A = { [void](Start-Task 'Local users' { Show-LocalUsers }) } }
    @{ T = 'Create user'; S = 'Local account'; V = 'primary'; A = {
            $u = Get-V 'usr.name'; if (-not $u) { Show-Msg 'Type a user name.' 'Warning'; return }
            [void](Start-Task 'Create user' { New-TqnyUser -User $P.U -Password $P.Pw -Admin $P.A } -Params @{ U = $u; Pw = (Get-V 'usr.pass'); A = (Get-V 'usr.admin') } -Admin)
        } }
    @{ T = 'Set password'; S = 'For the user named above'; A = {
            $u = Get-V 'usr.name'; if (-not $u) { Show-Msg 'Type the user name.' 'Warning'; return }
            if (Confirm-UI "Change the password of $u ?") { [void](Start-Task 'Set password' { Set-TqnyUserPassword -User $P.U -Password $P.Pw } -Params @{ U = $u; Pw = (Get-V 'usr.pass') } -Admin) }
        } }
    @{ T = 'Make administrator'; S = 'Add to Administrators'; A = { $u = Get-V 'usr.name'; if ($u) { [void](Start-Task 'Make admin' { Set-UserAdmin -User $P.U -Admin $true } -Params @{ U = $u } -Admin) } } }
    @{ T = 'Make standard user'; S = 'Remove from Administrators'; A = { $u = Get-V 'usr.name'; if ($u -and (Confirm-UI "Remove $u from Administrators?")) { [void](Start-Task 'Make standard' { Set-UserAdmin -User $P.U -Admin $false } -Params @{ U = $u } -Admin) } } }
    @{ T = 'Enable built-in Administrator'; S = 'Uses the password above'; V = 'danger'; A = { if (Confirm-UI 'Enable the hidden built-in Administrator account?' 'Give it a strong password (type it in the Password box first).' -Danger) { [void](Start-Task 'Built-in admin on' { Set-BuiltinAdmin -On $true -Password $P.Pw } -Params @{ Pw = (Get-V 'usr.pass') } -Admin) } } }
    @{ T = 'Disable built-in Administrator'; S = ''; A = { [void](Start-Task 'Built-in admin off' { Set-BuiltinAdmin -On $false } -Admin) } }
    @{ T = 'Auto sign-in / users'; S = 'Opens netplwiz'; A = { Open-Thing 'netplwiz.exe' } }
)

$c = Add-Card $pg 'Windows features'
Add-Tiles $c @(
    @{ T = '.NET Framework 3.5'; S = 'For older apps'; A = { [void](Start-Task '.NET 3.5' { Enable-NetFx3 } -Admin) } }
    @{ T = 'Create a restore point'; S = 'Before big changes'; A = { [void](Start-Task 'Restore point' { New-TqnyRestorePoint 'TQNY-Setup manual' } -Admin) } }
    @{ T = 'Windows features'; S = 'Open optional features'; A = { Open-Thing 'optionalfeatures.exe' } }
    @{ T = 'System restore'; S = 'Go back to a restore point'; A = { Open-Thing 'rstrui.exe' } }
)


# ===========================================================================
#  PAGES - part 2: Network, Wi-Fi, Sharing, Printers
# ===========================================================================
Add-NavGroup 'Network'

# ---- Network ---------------------------------------------------------------------------
$pg = Add-Page 'network' 'Network' 'Diagnose first (read only), then fix: IP and DNS, repairs, visibility and remote access.' 'E968'

$c = Add-Card $pg 'Diagnose - read only' 'Tests each layer separately - cable/Wi-Fi, DHCP, gateway, routing, DNS, web - so you can see exactly which one is broken.'
Add-Tiles $c @(
    @{ T = 'Check the internet'; S = 'Changes nothing'; V = 'primary'; A = { [void](Start-Task 'Internet check' { [void](Test-Internet) }) } }
    @{ T = 'Connection details'; S = 'Name, IPs, RDP, public IP'; A = { [void](Start-Task 'Connection details' { Show-ConnectionInfo }) } }
    @{ T = 'Adapters and IP config'; S = 'Every adapter, IP, DNS'; A = { [void](Start-Task 'Adapters' { Show-AdapterDetail }) } }
    @{ T = 'Discovery services'; S = 'Needed to be seen on the network'; A = { [void](Start-Task 'Discovery services' { Show-DiscoveryServices }) } }
)

$c = Add-Card $pg 'Test a host'
Add-Fields $c @(
    @{ L = 'Host name or IP'; C = (New-Input 'net.host' '8.8.8.8' 220) }
    @{ L = 'Port (for the port test)'; C = (New-Input 'net.port' '443' 90) }
)
Add-Tiles $c @(
    @{ T = 'Ping'; S = '4 echo requests'; A = { $h = Get-V 'net.host'; if ($h) { [void](Start-Task "Ping $h" { Invoke-PingTool $P.H 'ping' } -Params @{ H = $h }) } } }
    @{ T = 'Trace route'; S = 'Every hop to the host'; A = { $h = Get-V 'net.host'; if ($h) { [void](Start-Task "Trace $h" { Invoke-PingTool $P.H 'trace' } -Params @{ H = $h }) } } }
    @{ T = 'DNS lookup'; S = 'nslookup'; A = { $h = Get-V 'net.host'; if ($h) { [void](Start-Task "DNS $h" { Invoke-PingTool $P.H 'dns' } -Params @{ H = $h }) } } }
    @{ T = 'Test the port'; S = 'Is TCP port open?'; A = {
            $h = Get-V 'net.host'; $pt = Get-V 'net.port'
            if (-not $h -or $pt -notmatch '^\d{1,5}$') { Show-Msg 'Type a host and a port number.' 'Warning'; return }
            [void](Start-Task "Port $h`:$pt" { Invoke-PingTool $P.H 'port' $P.Pt } -Params @{ H = $h; Pt = $pt })
        } }
    @{ T = 'Public IP'; S = 'How this network looks online'; A = { [void](Start-Task 'Public IP' { Show-PublicIp }) } }
)

$c = Add-Card $pg 'Scan the network - read only' 'Lists every live device with its name, MAC and ping, marks this PC, and flags names already using your prefix.'
Add-Fields $c @(@{ L = 'Subnet (blank = this network)'; C = (New-Input 'net.base' '' 160 'First three numbers, e.g. 192.168.1') })
Add-Tiles $c @(@{ T = 'Scan the network'; S = 'Takes a few seconds'; V = 'primary'; A = { [void](Start-Task 'Network scan' { Invoke-NetScan $P.B } -Params @{ B = (Get-V 'net.base') }) } })

$c = Add-Card $pg 'IP address and DNS'
Add-Fields $c @(
    @{ L = 'Adapter'; C = (New-Combo 'net.adapter' -Wd 230) }
    @{ L = 'Mode'; C = (New-Combo 'net.mode' @('DHCP (automatic)', 'Static') 'DHCP (automatic)' 160) }
    @{ L = 'IP address'; C = (New-Input 'net.ip' '' 140) }
    @{ L = 'Subnet mask or /24'; C = (New-Input 'net.mask' '255.255.255.0' 130) }
    @{ L = 'Gateway'; C = (New-Input 'net.gw' '' 140) }
    @{ L = 'DNS 1'; C = (New-Input 'net.dns1' '' 130) }
    @{ L = 'DNS 2'; C = (New-Input 'net.dns2' '' 130) }
)
Add-Tiles $c @(
    @{ T = 'Load current settings'; S = 'Fill the boxes from the adapter'; A = { Import-AdapterFields } }
    @{ T = 'Apply IP settings'; S = 'DHCP or the static values'; V = 'primary'; A = {
            $a = Get-V 'net.adapter'; if (-not $a) { Show-Msg 'Pick an adapter.' 'Warning'; return }
            $mode = if ((Get-V 'net.mode') -like 'DHCP*') { 'DHCP' } else { 'Static' }
            $p = @{ A = $a; M = $mode; Ip = (Get-V 'net.ip'); Mask = (Get-V 'net.mask'); Gw = (Get-V 'net.gw'); D1 = (Get-V 'net.dns1'); D2 = (Get-V 'net.dns2') }
            if ($mode -eq 'Static' -and -not $p.Ip) { Show-Msg 'Type the static IP address.' 'Warning'; return }
            $what = if ($mode -eq 'DHCP') { "$a -> automatic (DHCP)" } else { "$a -> $($p.Ip) / $($p.Mask), gateway $($p.Gw), DNS $($p.D1) $($p.D2)" }
            if (Confirm-UI 'Change the IP settings?' "$what`n`nThe connection drops for a moment. If you are connected remotely you may lose the session." -Danger) {
                [void](Start-Task 'IP settings' { Set-AdapterAddress -Adapter $P.A -Mode $P.M -Ip $P.Ip -Mask $P.Mask -Gw $P.Gw -Dns1 $P.D1 -Dns2 $P.D2 } -Params $p -Admin)
            }
        } }
)
Add-Fields $c @(@{ L = 'DNS preset'; C = (New-Combo 'net.dnspreset' -Wd 300) })
Set-ComboPairs $UI['net.dnspreset'] @(@('Automatic (from the router / DHCP)', ''), @('Google  8.8.8.8 / 8.8.4.4', '8.8.8.8,8.8.4.4'), @('Cloudflare  1.1.1.1 / 1.0.0.1', '1.1.1.1,1.0.0.1'),
    @('Quad9  9.9.9.9 / 149.112.112.112', '9.9.9.9,149.112.112.112'), @('OpenDNS  208.67.222.222 / .220.220', '208.67.222.222,208.67.220.220'),
    @('AdGuard (blocks ads)  94.140.14.14 / 15.15', '94.140.14.14,94.140.15.15'), @('Use DNS 1 / DNS 2 boxes above', 'boxes'))
Add-Tiles $c @(@{ T = 'Apply DNS only'; S = 'Leaves the IP as it is'; A = {
            $a = Get-V 'net.adapter'; if (-not $a) { Show-Msg 'Pick an adapter.' 'Warning'; return }
            $v = Get-V 'net.dnspreset'
            $servers = if ($v -eq 'boxes') { @((Get-V 'net.dns1'), (Get-V 'net.dns2')) | Where-Object { $_ } } elseif ($v) { $v.Split(',') } else { @() }
            [void](Start-Task 'DNS' { Set-AdapterDns -Adapter $P.A -Servers $P.S } -Params @{ A = $a; S = @($servers) } -Admin)
        } })

function Update-AdapterCombo {
    $names = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Not Present' } |
            Sort-Object @{ e = { if ($_.Status -eq 'Up') { 0 } else { 1 } } }, ifIndex | ForEach-Object { $_.Name })
    Set-ComboItems $UI['net.adapter'] $names
}
function Import-AdapterFields {
    $a = Get-V 'net.adapter'
    if (-not $a) { return }
    $i = Get-AdapterIpInfo $a
    if (-not $i) { Say "  No adapter named $a." 'warn'; return }
    Set-V 'net.ip' $i.IP; Set-V 'net.mask' $i.Mask; Set-V 'net.gw' $i.GW
    Set-V 'net.dns1' $(if ($i.DNS.Count -gt 0) { $i.DNS[0] } else { '' }); Set-V 'net.dns2' $(if ($i.DNS.Count -gt 1) { $i.DNS[1] } else { '' })
    $UI['net.mode'].SelectedIndex = $(if ($i.DHCP -eq 'Enabled') { 0 } else { 1 })
    Say "  Loaded the current settings of $a (DHCP $($i.DHCP))." 'dim'
}
$PageInit['network'] = { Update-AdapterCombo }

$c = Add-Card $pg 'Fix the connection' 'From gentle to strong. Try them in order.'
Add-Tiles $c @(
    @{ T = 'Flush DNS'; S = 'Clears old name lookups'; A = { [void](Start-Task 'Flush DNS' { Invoke-NetRepair @('flush') }) } }
    @{ T = 'Release and renew IP'; S = 'Ask DHCP again'; A = { [void](Start-Task 'Renew IP' { Invoke-NetRepair @('renew') } -Admin) } }
    @{ T = 'Reset proxy settings'; S = 'When web pages will not load'; A = { [void](Start-Task 'Reset proxy' { Invoke-NetRepair @('proxy') } -Admin) } }
    @{ T = 'Restart network adapters'; S = 'Off and on again'; A = { [void](Start-Task 'Restart adapters' { Invoke-NetRepair @('adapters') } -Admin) } }
    @{ T = 'Reset network stack'; S = 'Winsock + TCP/IP. Needs a restart.'; V = 'danger'; A = {
            if (Confirm-UI 'Reset Winsock and the TCP/IP stack?' 'Static IPs and VPN adapters may need to be set again afterwards. A restart is needed.' -Danger) {
                [void](Start-Task 'Reset network stack' { Invoke-NetRepair @('stack') } -Admin -OnDone { Request-Restart 'The network stack was reset.' })
            }
        } }
    @{ T = 'Do all of the above'; S = 'Full network repair + restart'; V = 'danger'; A = {
            if (Confirm-UI 'Run every network repair?' 'Flush DNS, clear ARP, reset proxy, renew IP, restart adapters and reset the stack. A restart is needed.' -Danger) {
                [void](Start-Task 'Full network repair' { Invoke-NetRepair @('flush', 'arp', 'proxy', 'renew', 'adapters', 'stack') } -Admin -OnDone { Request-Restart 'The network was fully reset.' })
            }
        } }
)

$c = Add-Card $pg 'Visibility and remote access'
Add-Note $c 'Make visible: Private profile + Network Discovery + File and Printer Sharing (Private only) + discovery services on Automatic. Public stays locked down. Shares and SMB1 are not touched.'
Add-Tiles $c @(
    @{ T = 'Make this PC visible'; S = 'So its shares and printers can be reached'; V = 'primary'; A = { if (Confirm-UI 'Make this PC visible on the network?' 'Sets the active adapter to Private and enables discovery and file/printer sharing for Private networks only.') { [void](Start-Task 'Network visibility' { Enable-NetworkVisibility } -Admin) } } }
    @{ T = 'Network = Private'; S = 'Trusted office / home'; A = { [void](Start-Task 'Private profile' { Set-NetProfile 'Private' } -Admin) } }
    @{ T = 'Network = Public'; S = 'Hide this PC'; A = { [void](Start-Task 'Public profile' { Set-NetProfile 'Public' } -Admin) } }
    @{ T = 'Enable Remote Desktop'; S = 'Lets you connect later'; A = {
            if (Confirm-UI 'Enable Remote Desktop on this PC?' 'Anyone who can reach this PC can then try to sign in. Only on a trusted network, for a customer who wants remote support.' -Danger) {
                [void](Start-Task 'Remote Desktop on' { Set-RemoteDesktop $true } -Admin)
            }
        } }
    @{ T = 'Disable Remote Desktop'; S = ''; A = { [void](Start-Task 'Remote Desktop off' { Set-RemoteDesktop $false } -Admin) } }
    @{ T = 'Edit the hosts file'; S = 'Opens Notepad as admin'; A = { Open-Thing 'notepad.exe' "$env:SystemRoot\System32\drivers\etc\hosts" } }
    @{ T = 'Network connections'; S = 'ncpa.cpl'; A = { Open-Thing 'ncpa.cpl' } }
)

# ---- Wi-Fi --------------------------------------------------------------------------------
$pg = Add-Page 'wifi' 'Wi-Fi' 'Connect, see saved passwords, and carry every Wi-Fi network across a format.' 'E701'

$c = Add-Card $pg 'Status'
Add-Tiles $c @(
    @{ T = 'Wi-Fi status'; S = 'Signal, speed, channel'; A = { [void](Start-Task 'Wi-Fi status' { Show-WifiStatus }) } }
    @{ T = 'Networks in range'; S = 'Sorted by signal'; A = { [void](Start-Task 'Wi-Fi networks' { Show-WifiNetworks }) } }
    @{ T = 'Wi-Fi report'; S = 'Disconnects and errors, last 3 days'; A = { [void](Start-Task 'Wi-Fi report' { Show-WlanReport } -Admin) } }
    @{ T = 'Wi-Fi settings'; S = 'Open Settings'; A = { Open-Thing 'ms-settings:network-wifi' } }
)
Add-Note $c 'Windows 11 24H2 hides Wi-Fi names from command-line tools until Location is on. The tool tells you and opens the setting if that happens.'

$c = Add-Card $pg 'Connect to a network'
Add-Fields $c @(
    @{ L = 'Network name (SSID)'; C = (New-Input 'wifi.ssid' '' 220) }
    @{ L = 'Password'; C = (New-Pass 'wifi.pass' 200) }
    @{ L = 'Security'; C = (New-Combo 'wifi.sec' @('WPA2', 'WPA3', 'Open') 'WPA2' 110) }
)
Add-Checks $c @((New-Check 'wifi.hidden' 'Hidden network' $false))
Add-Tiles $c @(@{ T = 'Save and connect'; S = 'Saved for every user'; V = 'primary'; A = {
            $s = Get-V 'wifi.ssid'; if (-not $s) { Show-Msg 'Type the network name.' 'Warning'; return }
            [void](Start-Task "Connect $s" { Connect-Wifi -Ssid $P.S -Password $P.Pw -Security $P.Sec -Hidden $P.H } -Params @{ S = $s; Pw = (Get-V 'wifi.pass'); Sec = (Get-V 'wifi.sec'); H = (Get-V 'wifi.hidden') } -Admin)
        } })

$c = Add-Card $pg 'Saved networks' 'Back them up before formatting, restore after - every network comes back with its password.'
Add-Tiles $c @(
    @{ T = 'Show saved passwords'; S = 'Every saved network'; A = { [void](Start-Task 'Saved Wi-Fi' { Show-WifiPasswords } -Admin) } }
    @{ T = 'Back up to a folder'; S = 'One .xml per network'; A = { $f = Select-Folder 'Where to save the Wi-Fi networks'; if ($f) { [void](Start-Task 'Back up Wi-Fi' { [void](Export-WifiProfiles $P.F) } -Params @{ F = (Join-Path $f "WiFi-$($Facts.Name)") } -Admin) } } }
    @{ T = 'Restore from a folder'; S = 'Adds them for every user'; A = { $f = Select-Folder 'Folder with the Wi-Fi .xml files'; if ($f) { [void](Start-Task 'Restore Wi-Fi' { Import-WifiProfiles $P.F } -Params @{ F = $f } -Admin) } } }
)
Add-Fields $c @(@{ L = 'Forget this network'; C = (New-Input 'wifi.forget' '' 220) })
Add-Tiles $c @(@{ T = 'Forget network'; S = 'Delete the saved profile'; V = 'danger'; A = { $n = Get-V 'wifi.forget'; if ($n -and (Confirm-UI "Forget the Wi-Fi network '$n'?")) { [void](Start-Task 'Forget Wi-Fi' { Remove-WifiProfile $P.N } -Params @{ N = $n } -Admin) } } })

# ---- Sharing --------------------------------------------------------------------------------
$pg = Add-Page 'sharing' 'Sharing' 'Shared folders, password-protected sharing, network drives and the fixes for "cannot access \\PC".' 'E72D'

$c = Add-Card $pg 'Create a shared folder' 'Makes the folder, shares it, sets the permissions and turns on discovery - then prints the \\PC\Share path to give the customer.'
Add-Fields $c @(
    @{ L = 'Folder'; C = (New-Input 'sh.path' 'C:\TQNY-Share' 240) }
    @{ L = 'Share name'; C = (New-Input 'sh.name' 'TQNY-Share' 150) }
    @{ L = 'Who can use it'; C = (New-Combo 'sh.access' -Wd 250) }
    @{ L = 'User (for one user)'; C = (New-Input 'sh.user' 'share' 120) }
    @{ L = 'Password'; C = (New-Pass 'sh.pass' 140) }
)
Set-ComboPairs $UI['sh.access'] @(@('Everyone - read and write', 'Everyone-Full'), @('Everyone - read only', 'Everyone-Read'), @('One user with a password', 'User')) 'Everyone-Full'
Add-Tiles $c @(
    @{ T = 'Create and share'; S = 'Folder + share + permissions'; V = 'primary'; A = {
            $p = @{ Path = (Get-V 'sh.path'); Name = (Get-V 'sh.name'); Acc = (Get-V 'sh.access'); U = (Get-V 'sh.user'); Pw = (Get-V 'sh.pass') }
            if (-not $p.Path -or -not $p.Name) { Show-Msg 'Fill in the folder and the share name.' 'Warning'; return }
            if ($p.Acc -eq 'User' -and (-not $p.U -or -not $p.Pw)) { Show-Msg 'Type the user name and a password for the share user.' 'Warning'; return }
            if (Confirm-UI "Share $($p.Path) as \\$env:COMPUTERNAME\$($p.Name) ?" "Access: $($UI['sh.access'].SelectedItem.Content)") {
                [void](Start-Task 'Create share' { New-TqnyShare -Path $P.Path -Name $P.Name -Access $P.Acc -User $P.U -Password $P.Pw } -Params $p -Admin)
            }
        } }
    @{ T = 'List shares'; S = 'With their permissions'; A = { [void](Start-Task 'Shares' { Show-Shares }) } }
    @{ T = 'Stop sharing'; S = 'The share name above. Files stay.'; V = 'danger'; A = { $n = Get-V 'sh.name'; if ($n -and (Confirm-UI "Stop sharing '$n'?" 'The folder and its files are kept.')) { [void](Start-Task 'Remove share' { Remove-TqnyShare $P.N } -Params @{ N = $n } -Admin) } } }
    @{ T = 'Shared Folders console'; S = 'fsmgmt.msc'; A = { Open-Thing 'fsmgmt.msc' } }
)

$c = Add-Card $pg 'Password-protected sharing' 'OFF = shares open without asking for a password (small office). ON = Windows default, users must sign in.'
Add-Tiles $c @(
    @{ T = 'Turn password protection OFF'; S = 'Open access on this network'; V = 'danger'; A = {
            if (Confirm-UI 'Turn OFF password-protected sharing?' 'Enables the Guest account for network access. Anyone on this network can open shares that allow Everyone. Use only on a trusted office network.' -Danger) {
                [void](Start-Task 'Password sharing OFF' { Set-PasswordSharing $false } -Admin)
            }
        } }
    @{ T = 'Turn password protection ON'; S = 'Windows default'; A = { [void](Start-Task 'Password sharing ON' { Set-PasswordSharing $true } -Admin) } }
    @{ T = 'Advanced sharing settings'; S = 'Open the Windows page'; A = { Open-Thing 'control.exe' '/name Microsoft.NetworkAndSharingCenter /page Advanced' } }
)

$c = Add-Card $pg 'This PC cannot open other PCs or the NAS' 'Windows 11 24H2 blocks guest access and requires SMB signing by default, which breaks many NAS boxes and older shares.'
Add-Tiles $c @(
    @{ T = 'Allow older shares / NAS'; S = 'Guest access + unsigned SMB'; V = 'danger'; A = { if (Confirm-UI 'Allow guest access and unsigned SMB on this PC?' 'This lowers SMB security on this PC. Use it when a NAS or older PC cannot be opened.' -Danger) { [void](Start-Task 'SMB compatibility' { Set-SmbClientCompat $true } -Admin) } } }
    @{ T = 'Back to secure default'; S = 'Undo the above'; A = { [void](Start-Task 'SMB secure default' { Set-SmbClientCompat $false } -Admin) } }
    @{ T = 'SMB1 on'; S = 'Only for very old scanners / NAS'; V = 'danger'; A = { if (Confirm-UI 'Enable SMB1?' 'SMB1 is insecure (WannaCry). Enable only when an old scanner or NAS cannot do SMB2. Needs a restart.' -Danger) { [void](Start-Task 'SMB1 on' { Set-Smb1 $true } -Admin) } } }
    @{ T = 'SMB1 off'; S = 'Recommended'; A = { [void](Start-Task 'SMB1 off' { Set-Smb1 $false } -Admin) } }
)

$c = Add-Card $pg 'Saved logins for other PCs' 'Save the user name and password for a server once, so its shares and printers open without asking.'
Add-Fields $c @(
    @{ L = 'Server name or IP'; C = (New-Input 'cred.server' '' 180) }
    @{ L = 'User'; C = (New-Input 'cred.user' '' 150) }
    @{ L = 'Password'; C = (New-Pass 'cred.pass' 150) }
)
Add-Tiles $c @(
    @{ T = 'Save login'; S = 'Windows Credential Manager'; A = { $s = Get-V 'cred.server'; if (-not $s) { return }; [void](Start-Task 'Save login' { Add-SavedCredential -Server $P.S -User $P.U -Password $P.Pw } -Params @{ S = $s; U = (Get-V 'cred.user'); Pw = (Get-V 'cred.pass') }) } }
    @{ T = 'Show saved logins'; S = ''; A = { [void](Start-Task 'Saved logins' { Show-SavedCredentials }) } }
    @{ T = 'Remove saved login'; S = 'For the server above'; A = { $s = Get-V 'cred.server'; if ($s) { [void](Start-Task 'Remove login' { Remove-SavedCredential $P.S } -Params @{ S = $s }) } } }
)

$c = Add-Card $pg 'Network drives'
Add-Fields $c @(
    @{ L = 'Letter'; C = (New-Input 'map.letter' 'S' 60) }
    @{ L = 'Folder (\\server\share)'; C = (New-Input 'map.path' '' 240) }
    @{ L = 'User (optional)'; C = (New-Input 'map.user' '' 140) }
    @{ L = 'Password'; C = (New-Pass 'map.pass' 140) }
)
Add-Tiles $c @(
    @{ T = 'Map drive'; S = 'Reconnects at every sign-in'; V = 'primary'; A = {
            $l = Get-V 'map.letter'; $pth = Get-V 'map.path'
            if (-not $l -or -not $pth) { Show-Msg 'Type the letter and the \\server\share path.' 'Warning'; return }
            [void](Start-Task 'Map drive' { Add-MappedDrive -Letter $P.L -Path $P.Pa -User $P.U -Password $P.Pw } -Params @{ L = $l; Pa = $pth; U = (Get-V 'map.user'); Pw = (Get-V 'map.pass') })
        } }
    @{ T = 'Disconnect drive'; S = 'The letter above'; A = { $l = Get-V 'map.letter'; if ($l) { [void](Start-Task 'Disconnect drive' { Remove-MappedDrive $P.L } -Params @{ L = $l }) } } }
    @{ T = 'Show mapped drives'; S = 'net use'; A = { [void](Start-Task 'Mapped drives' { Head 'Mapped drives'; [void](Invoke-Native net.exe @('use')) }) } }
)

# ---- Printers -------------------------------------------------------------------------------
$pg = Add-Page 'printers' 'Printers and scanners' 'Find them on the network, add them (driverless when possible), fix the spooler and the shared-printer errors.' 'E749'

$c = Add-Card $pg 'Find - read only' 'Probes ports 9100 / 515 / 631, asks each printer its model over SNMP and detects network scanners (eSCL).'
Add-Fields $c @(@{ L = 'Subnet (blank = this network)'; C = (New-Input 'pr.base' '' 160) })
Add-Tiles $c @(@{ T = 'Find printers and scanners'; S = 'A few seconds'; V = 'primary'; A = { [void](Start-Task 'Find printers' { Find-Printers $P.B } -Params @{ B = (Get-V 'pr.base') }) } })

$c = Add-Card $pg 'Add a printer'
Add-Fields $c @(
    @{ L = 'Method'; C = (New-Combo 'pr.method' -Wd 260) }
    @{ L = 'Printer IP'; C = (New-Input 'pr.ip' '' 140) }
    @{ L = 'Name to show'; C = (New-Input 'pr.name' '' 200) }
    @{ L = 'Driver (TCP/IP method)'; C = (New-Combo 'pr.driver' -Wd 300 -Editable -Tip 'Pick an installed driver, or type the exact driver name from the vendor package.') }
    @{ L = 'Shared printer (\\PC\Printer)'; C = (New-Input 'pr.share' '' 240) }
)
Set-ComboPairs $UI['pr.method'] @(@('IPP - driverless (modern printers)', 'IPP'), @('TCP/IP port 9100 + driver', 'TCP'), @('Shared printer on another PC', 'Shared')) 'IPP'
Add-Tiles $c @(
    @{ T = 'Add printer'; S = 'Using the method above'; V = 'primary'; A = {
            $p = @{ M = (Get-V 'pr.method'); Ip = (Get-V 'pr.ip'); N = (Get-V 'pr.name'); D = (Get-V 'pr.driver'); S = (Get-V 'pr.share') }
            if ($p.M -ne 'Shared' -and -not $p.Ip) { Show-Msg 'Type the printer IP (use Find printers to see it).' 'Warning'; return }
            if ($p.M -eq 'Shared' -and -not $p.S) { Show-Msg 'Type the shared printer as \\PC\PrinterName.' 'Warning'; return }
            [void](Start-Task 'Add printer' { Add-NetPrinter -Method $P.M -Ip $P.Ip -Name $P.N -Driver $P.D -Share $P.S } -Params $p -Admin -OnDone { Update-PrinterCombos })
        } }
    @{ T = 'Refresh driver list'; S = 'After installing a driver'; A = { Update-PrinterCombos; Say '  Printer and driver lists refreshed.' 'dim' } }
)

$c = Add-Card $pg 'Installed printers'
Add-Fields $c @(
    @{ L = 'Printer'; C = (New-Combo 'pr.sel' -Wd 300) }
    @{ L = 'Share as (for Share)'; C = (New-Input 'pr.sharename' '' 160) }
)
Add-Tiles $c @(
    @{ T = 'List printers'; S = 'Driver, port, status'; A = { [void](Start-Task 'Printers' { Show-Printers }) } }
    @{ T = 'Test print'; S = 'Windows test page'; V = 'primary'; A = { $n = Get-V 'pr.sel'; if ($n) { [void](Start-Task 'Test print' { Invoke-TestPrint $P.N } -Params @{ N = $n }) } } }
    @{ T = 'Set as default'; S = 'And stop Windows changing it'; A = { $n = Get-V 'pr.sel'; if ($n) { [void](Start-Task 'Default printer' { Set-DefaultPrinter $P.N } -Params @{ N = $n }) } } }
    @{ T = 'Share this printer'; S = 'Other PCs can connect'; A = { $n = Get-V 'pr.sel'; if ($n) { [void](Start-Task 'Share printer' { Set-PrinterSharing -Name $P.N -ShareName $P.S } -Params @{ N = $n; S = (Get-V 'pr.sharename') } -Admin -OnDone { Update-PrinterCombos }) } } }
    @{ T = 'Remove printer'; S = ''; V = 'danger'; A = { $n = Get-V 'pr.sel'; if ($n -and (Confirm-UI "Remove the printer '$n'?")) { [void](Start-Task 'Remove printer' { Remove-TqnyPrinter $P.N } -Params @{ N = $n } -Admin -OnDone { Update-PrinterCombos }) } } }
)

$c = Add-Card $pg 'Fix printing'
Add-Tiles $c @(
    @{ T = 'Clear stuck print jobs'; S = 'Empties the queue + restarts spooler'; V = 'primary'; A = { if (Confirm-UI 'Delete every waiting print job and restart the spooler?') { [void](Start-Task 'Clear print queue' { Restart-Spooler $true } -Admin) } } }
    @{ T = 'Restart print spooler'; S = 'When printing hangs'; A = { [void](Start-Task 'Restart spooler' { Restart-Spooler } -Admin) } }
    @{ T = 'Fix shared printer errors'; S = '0x0000011b / 0x00000709 / 0x00000bcb'; A = { if (Confirm-UI 'Apply the shared-printer compatibility settings?' 'Run it on BOTH the PC sharing the printer and the PC connecting to it.') { [void](Start-Task 'Shared printer fix' { Repair-SharedPrinting } -Admin) } } }
    @{ T = 'Printers and scanners'; S = 'Open Settings'; A = { Open-Thing 'ms-settings:printers' } }
    @{ T = 'Print Management'; S = 'printmanagement.msc (Pro)'; A = { Open-Thing 'printmanagement.msc' } }
)

$c = Add-Card $pg 'Drivers' 'Modern MFPs print with no driver over IPP. If a model needs the vendor driver, open the official page, download, extract, then install from the folder.'
Add-Fields $c @(
    @{ L = 'Vendor'; C = (New-Combo 'pr.vendor' -Wd 280) }
    @{ L = 'Extracted driver folder'; C = (New-Input 'pr.drvfolder' '' 300) }
)
Set-ComboPairs $UI['pr.vendor'] @(
    @('HP / Samsung (Universal Print Driver)', 'https://support.hp.com/us-en/drivers/printers'),
    @('Kyocera (KX driver, ECOSYS / TASKalfa)', 'https://www.kyoceradocumentsolutions.com/en/support/downloads.html'),
    @('Develop (ineo)', 'https://www.develop.eu/en/support/download-center/'),
    @('Konica Minolta (bizhub)', 'https://www.konicaminolta.eu/eu-en/support/download-centre'),
    @('Canon', 'https://www.canon-me.com/support/'),
    @('Epson', 'https://epson.com/Support/sl/s'),
    @('Brother', 'https://support.brother.com/'),
    @('Ricoh', 'https://www.ricoh.com/support'),
    @('Xerox', 'https://www.support.xerox.com/'),
    @('Sharp', 'https://global.sharp/products/copier/downloads/'),
    @('Lexmark', 'https://support.lexmark.com/'))
Add-Tiles $c @(
    @{ T = 'Open driver page'; S = 'Official vendor site'; A = { $u = Get-V 'pr.vendor'; if ($u) { Open-Thing $u } } }
    @{ T = 'Browse...'; S = 'Pick the extracted folder'; A = { $f = Select-Folder 'Folder with the extracted printer driver (.inf files)'; if ($f) { Set-V 'pr.drvfolder' $f } } }
    @{ T = 'Install driver from folder'; S = 'Adds every .inf in it'; V = 'primary'; A = {
            $f = Get-V 'pr.drvfolder'; if (-not $f) { Show-Msg 'Pick the driver folder first.' 'Warning'; return }
            [void](Start-Task 'Install printer driver' { Install-DriverFolder $P.F 'printer driver' } -Params @{ F = $f } -Admin -OnDone { Update-PrinterCombos })
        } }
)

$c = Add-Card $pg 'Scanners'
Add-Tiles $c @(
    @{ T = 'Add a scanner'; S = 'Windows finds eSCL / WSD scanners'; A = { Open-Thing 'ms-settings:printers'; Say '  Click "Add device" in the Settings window.' 'dim' } }
    @{ T = 'Install Fax and Scan'; S = 'Windows Fax and Scan app'; A = { [void](Start-Task 'Fax and Scan' { Install-FaxScan } -Admin) } }
    @{ T = 'Open Fax and Scan'; S = 'wfs.exe'; A = { Open-Thing 'wfs.exe' } }
    @{ T = 'Scan-to-folder share'; S = 'Go to Sharing, pick "One user"'; A = { Show-Page 'sharing'; Set-V 'sh.path' 'C:\Scans'; Set-V 'sh.name' 'Scans'; Set-V 'sh.access' 'User'; Set-V 'sh.user' 'scan' } }
)

function Update-PrinterCombos {
    $pr = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    Set-ComboItems $UI['pr.sel'] $pr
    $dr = @(Get-PrinterDriver -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object -Unique)
    Set-ComboItems $UI['pr.driver'] $dr
}
$PageInit['printers'] = { Update-PrinterCombos }


# ===========================================================================
#  PAGES - part 3: Security, Activation, Drivers, Backup, Repair, Cleanup,
#                  Reports, Tools, Names & settings
# ===========================================================================
Add-NavGroup 'System'

# ---- Security ---------------------------------------------------------------------------
$pg = Add-Page 'security' 'Security' 'Firewall, Windows Defender and BitLocker.' 'EA18'

$c = Add-Card $pg 'Firewall'
Add-Fields $c @(@{ L = 'Profile'; C = (New-Combo 'fw.profile' @('All', 'Domain', 'Private', 'Public') 'All' 140) })
Add-Tiles $c @(
    @{ T = 'Firewall status'; S = 'Each profile'; A = { [void](Start-Task 'Firewall status' { Show-FirewallStatus }) } }
    @{ T = 'Turn firewall ON'; S = 'For the profile above'; V = 'primary'; A = { [void](Start-Task 'Firewall on' { Set-FirewallState -Which $P.W -On $true } -Params @{ W = (Get-V 'fw.profile') } -Admin) } }
    @{ T = 'Turn firewall OFF'; S = 'Only for testing'; V = 'danger'; A = { $w2 = Get-V 'fw.profile'; if (Confirm-UI "Turn the firewall OFF for $w2 ?" 'Leaves the PC open on those networks. Turn it back on when done.' -Danger) { [void](Start-Task 'Firewall off' { Set-FirewallState -Which $P.W -On $false } -Params @{ W = $w2 } -Admin) } } }
    @{ T = 'Allow ping'; S = 'Private and Domain networks'; A = { [void](Start-Task 'Allow ping' { Set-PingRule $true } -Admin) } }
    @{ T = 'Block ping again'; S = 'Remove the rule'; A = { [void](Start-Task 'Block ping' { Set-PingRule $false } -Admin) } }
    @{ T = 'Reset to Windows defaults'; S = 'Removes every custom rule'; V = 'danger'; A = { if (Confirm-UI 'Reset the firewall to the Windows defaults?' 'Every custom rule is removed, including ones other software added.' -Danger) { [void](Start-Task 'Reset firewall' { Reset-Firewall } -Admin) } } }
    @{ T = 'Advanced firewall'; S = 'wf.msc'; A = { Open-Thing 'wf.msc' } }
)

$c = Add-Card $pg 'Open a port / allow an app'
Add-Fields $c @(
    @{ L = 'Rule name'; C = (New-Input 'fw.name' '' 160) }
    @{ L = 'Port(s), e.g. 3389 or 8000-8100'; C = (New-Input 'fw.port' '' 180) }
    @{ L = 'Protocol'; C = (New-Combo 'fw.proto' @('TCP', 'UDP', 'Both') 'TCP' 90) }
    @{ L = 'Networks'; C = (New-Combo 'fw.rprofile' @('Private', 'Domain', 'Public', 'All') 'Private' 110) }
)
Add-Tiles $c @(@{ T = 'Open port'; S = 'Inbound allow rule'; V = 'primary'; A = {
            $pt = Get-V 'fw.port'; if (-not $pt) { Show-Msg 'Type the port.' 'Warning'; return }
            [void](Start-Task 'Open port' { Add-PortRule -Name $P.N -Ports $P.Pt -Proto $P.Pr -Prof $P.Pf } -Params @{ N = (Get-V 'fw.name'); Pt = $pt; Pr = (Get-V 'fw.proto'); Pf = (Get-V 'fw.rprofile') } -Admin)
        } })
Add-Fields $c @(@{ L = 'Program (.exe)'; C = (New-Input 'fw.prog' '' 420) })
Add-Tiles $c @(
    @{ T = 'Browse...'; S = 'Pick the program'; A = { $f = Select-File 'Programs (*.exe)|*.exe'; if ($f) { Set-V 'fw.prog' $f } } }
    @{ T = 'Allow this program'; S = 'Inbound, Private and Domain'; A = { $f = Get-V 'fw.prog'; if ($f) { [void](Start-Task 'Allow program' { Add-ProgramRule $P.F } -Params @{ F = $f } -Admin) } } }
    @{ T = 'Show TQNY rules'; S = 'Rules this tool added'; A = { [void](Start-Task 'TQNY rules' { Show-TqnyRules }) } }
    @{ T = 'Remove TQNY rules'; S = 'Only the ones this tool added'; V = 'danger'; A = { if (Confirm-UI 'Remove every firewall rule added by TQNY-Setup?') { [void](Start-Task 'Remove TQNY rules' { Remove-TqnyRules } -Admin) } } }
)

$c = Add-Card $pg 'Windows Defender'
Add-Tiles $c @(
    @{ T = 'Defender status'; S = 'Real-time, Tamper, signatures'; A = { [void](Start-Task 'Defender status' { Show-DefenderStatus }) } }
    @{ T = 'Quick scan'; S = '2-10 minutes'; V = 'primary'; A = { [void](Start-Task 'Quick scan' { Invoke-DefenderTask 'quick' } -Admin) } }
    @{ T = 'Full scan'; S = 'An hour or more'; A = { if (Confirm-UI 'Run a full scan of every file?' 'This takes a long time. You can keep working.') { [void](Start-Task 'Full scan' { Invoke-DefenderTask 'full' } -Admin) } } }
    @{ T = 'Update signatures'; S = 'Latest virus definitions'; A = { [void](Start-Task 'Defender update' { Invoke-DefenderTask 'update' } -Admin) } }
    @{ T = 'Real-time ON'; S = ''; A = { [void](Start-Task 'Real-time on' { Set-DefenderRealtime $true } -Admin) } }
    @{ T = 'Real-time OFF'; S = 'Tamper Protection must be off'; V = 'danger'; A = { if (Confirm-UI 'Turn Defender real-time protection OFF?' 'The PC is unprotected until it is turned back on (Windows also turns it back on by itself after a while).' -Danger) { [void](Start-Task 'Real-time off' { Set-DefenderRealtime $false } -Admin) } } }
    @{ T = 'Windows Security'; S = 'Open the app'; A = { Open-Thing 'windowsdefender:' } }
)
Add-Fields $c @(@{ L = 'Folder to exclude from scanning'; C = (New-Input 'def.excl' '' 420) })
Add-Tiles $c @(
    @{ T = 'Browse...'; S = ''; A = { $f = Select-Folder 'Folder to exclude from Defender'; if ($f) { Set-V 'def.excl' $f } } }
    @{ T = 'Add exclusion'; S = 'For trusted software that gets flagged'; V = 'danger'; A = { $f = Get-V 'def.excl'; if ($f -and (Confirm-UI "Stop Defender scanning $f ?" 'Only for trusted software. Malware placed there would not be detected.' -Danger)) { [void](Start-Task 'Defender exclusion' { Invoke-DefenderTask 'exclude' $P.F } -Params @{ F = $f } -Admin) } } }
)

$c = Add-Card $pg 'BitLocker' 'Windows 11 turns on device encryption by itself on many new PCs. Save the recovery key BEFORE you format or change the motherboard.'
Add-Tiles $c @(
    @{ T = 'BitLocker status'; S = 'Every drive'; A = { [void](Start-Task 'BitLocker status' { Show-BitLocker } -Admin) } }
    @{ T = 'Show recovery keys'; S = 'Write them down'; V = 'primary'; A = { [void](Start-Task 'BitLocker keys' { Show-BitLocker $true } -Admin) } }
    @{ T = 'Suspend for one restart'; S = 'Before a BIOS update'; A = { [void](Start-Task 'Suspend BitLocker' { Set-BitLockerAction 'suspend' } -Admin) } }
    @{ T = 'Turn off BitLocker'; S = 'Decrypt the system drive'; V = 'danger'; A = { if (Confirm-UI "Turn off BitLocker and decrypt $env:SystemDrive ?" 'Decryption runs in the background and can take a long time. The PC stays usable.' -Danger) { [void](Start-Task 'BitLocker off' { Set-BitLockerAction 'off' } -Admin) } } }
)

# ---- Activation ---------------------------------------------------------------------------
$pg = Add-Page 'activation' 'Activation' 'Windows and Office licence status, and activation with genuine product keys.' 'E8D7'

$c = Add-Card $pg 'Windows'
Add-Fields $c @(@{ L = 'Product key (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX)'; C = (New-Input 'act.win' '' 330) })
Add-Tiles $c @(
    @{ T = 'Activation status'; S = 'Edition, channel, expiry'; A = { [void](Start-Task 'Windows activation' { Show-WindowsActivation }) } }
    @{ T = 'Show BIOS (OEM) key'; S = 'Key the PC was sold with'; A = { [void](Start-Task 'OEM key' { [void](Show-OemKey) } -Admin) } }
    @{ T = 'Activate with this key'; S = 'Install key + activate online'; V = 'primary'; A = { $k = Get-V 'act.win'; if (-not $k) { Show-Msg 'Type the product key.' 'Warning'; return }; if (Confirm-UI 'Install this product key and activate Windows?') { [void](Start-Task 'Activate Windows' { Install-WindowsKey $P.K } -Params @{ K = $k } -Admin) } } }
    @{ T = 'Use the BIOS key'; S = 'Re-activate an OEM PC'; A = { if (Confirm-UI 'Install the key stored in the BIOS and activate?') { [void](Start-Task 'Activate with OEM key' { Install-WindowsKey 'OEM' } -Admin) } } }
    @{ T = 'Activation settings'; S = 'Troubleshooter, change key'; A = { Open-Thing 'ms-settings:activation' } }
)

$c = Add-Card $pg 'Office'
Add-Fields $c @(@{ L = 'Office product key'; C = (New-Input 'act.office' '' 330) })
Add-Tiles $c @(
    @{ T = 'Office status'; S = 'Volume / retail Office'; A = { [void](Start-Task 'Office activation' { Show-OfficeActivation }) } }
    @{ T = 'Activate Office'; S = 'Install key + activate'; V = 'primary'; A = { $k = Get-V 'act.office'; if (-not $k) { Show-Msg 'Type the Office key.' 'Warning'; return }; [void](Start-Task 'Activate Office' { Install-OfficeKey $P.K } -Params @{ K = $k } -Admin) } }
)
Add-Note $c 'Microsoft 365 is activated by signing in to Word / Excel with the licensed account. Genuine licences: tqny.store'

# ---- Drivers ---------------------------------------------------------------------------------
$pg = Add-Page 'drivers' 'Drivers' 'Find missing drivers, install them from Windows Update or a folder, and carry drivers across a format.' 'E772'

$c = Add-Card $pg 'Check'
Add-Tiles $c @(
    @{ T = 'Devices with problems'; S = 'Missing or failed drivers'; V = 'primary'; A = { [void](Start-Task 'Problem devices' { Show-ProblemDevices }) } }
    @{ T = 'Third-party drivers'; S = 'What is installed, versions'; A = { [void](Start-Task 'Installed drivers' { Show-ThirdPartyDrivers }) } }
    @{ T = 'Scan for hardware changes'; S = 'After plugging something in'; A = { [void](Start-Task 'Hardware rescan' { Invoke-HardwareRescan } -Admin) } }
    @{ T = 'Device Manager'; S = 'devmgmt.msc'; A = { Open-Thing 'devmgmt.msc' } }
)

$c = Add-Card $pg 'Get drivers'
Add-Note $c '' '#C9D3DF' 'drv.maker'
Add-Tiles $c @(
    @{ T = 'Drivers from Windows Update'; S = 'Installs every offered driver'; V = 'primary'; A = { if (Confirm-UI 'Install every driver Windows Update offers for this PC?') { [void](Start-Task 'Driver updates' { Install-WindowsUpdates -Kind 'Driver' } -Admin) } } }
    @{ T = 'Manufacturer support page'; S = 'Drivers for this exact model'; A = { Open-Thing (Get-MakerSupportUrl) } }
    @{ T = 'Intel Driver Assistant'; S = 'Intel graphics, Wi-Fi, chipset'; A = { Open-Thing 'https://www.intel.com/content/www/us/en/support/intel-driver-support-assistant.html' } }
    @{ T = 'AMD drivers'; S = 'Radeon / Ryzen chipset'; A = { Open-Thing 'https://www.amd.com/en/support/download/drivers.html' } }
    @{ T = 'NVIDIA drivers'; S = 'GeForce / RTX / Quadro'; A = { Open-Thing 'https://www.nvidia.com/en-us/drivers/' } }
)

function Get-MakerSupportUrl {
    $m = [string]$Facts.Manufacturer
    switch -Regex ($m) {
        'Dell' { return 'https://www.dell.com/support/home' }
        'HP|Hewlett' { return 'https://support.hp.com/drivers' }
        'Lenovo' { return 'https://pcsupport.lenovo.com' }
        'ASUS' { return 'https://www.asus.com/support/download-center/' }
        'Acer' { return 'https://www.acer.com/support/drivers-and-manuals' }
        'MSI|Micro-Star' { return 'https://www.msi.com/support/download' }
        'Gigabyte' { return 'https://www.gigabyte.com/Support' }
        'Microsoft' { return 'https://support.microsoft.com/surface/download-drivers-and-firmware-for-surface' }
        'Samsung' { return 'https://www.samsung.com/support/' }
        'Toshiba|Dynabook' { return 'https://support.dynabook.com/' }
        default { return 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$m $($Facts.ModelRaw) drivers") }
    }
}
$PageInit['drivers'] = { $UI['drv.maker'].Text = "This PC: $($Facts.Manufacturer) $($Facts.ModelRaw)   serial $($Facts.BiosSerial)" }

$c = Add-Card $pg 'Back up / restore drivers' 'Before formatting, back up the drivers to USB. After the format, install them all from that folder - no hunting for network drivers.'
Add-Fields $c @(@{ L = 'Drivers folder'; C = (New-Input 'drv.folder' '' 420) })
Add-Tiles $c @(
    @{ T = 'Browse...'; S = ''; A = { $f = Select-Folder 'Drivers folder'; if ($f) { Set-V 'drv.folder' $f } } }
    @{ T = 'Back up drivers'; S = 'Every third-party driver'; A = { $f = Get-V 'drv.folder'; if (-not $f) { Show-Msg 'Pick a folder first.' 'Warning'; return }; [void](Start-Task 'Back up drivers' { Export-Drivers $P.F } -Params @{ F = $f } -Admin) } }
    @{ T = 'Install drivers from folder'; S = 'Every .inf, all sub-folders'; V = 'primary'; A = { $f = Get-V 'drv.folder'; if (-not $f) { Show-Msg 'Pick a folder first.' 'Warning'; return }; [void](Start-Task 'Install drivers' { Install-DriverFolder $P.F } -Params @{ F = $f } -Admin) } }
)

# ---- Backup and restore ----------------------------------------------------------------------
$pg = Add-Page 'backup' 'Backup and restore' 'Before a format: save the user''s files, Wi-Fi, drivers, apps and printers. After the format: put them all back.' 'E74E'

$c = Add-Card $pg '1. Before the format - back up' 'Nothing on this PC is changed or deleted. Copy to a USB disk or another drive, never to the drive you are about to format.'
Add-Fields $c @(
    @{ L = 'User'; C = (New-Combo 'bk.user' -Wd 200) }
    @{ L = 'Save to'; C = (New-Input 'bk.dest' '' 420) }
)
Add-Checks $c @(
    (New-Check 'bk.files' 'Desktop, Documents, Downloads, Pictures, Videos, Music' $true 'Follows OneDrive / redirected folders for the user running the tool.'),
    (New-Check 'bk.bookmarks' 'Browser bookmarks (Chrome, Edge, Brave, Firefox)' $true),
    (New-Check 'bk.wifi' 'Wi-Fi networks and passwords' $true),
    (New-Check 'bk.drivers' 'Drivers' $true),
    (New-Check 'bk.apps' 'List of installed apps (to reinstall)' $true),
    (New-Check 'bk.printers' 'Printers, ports and drivers' $true),
    (New-Check 'bk.extras' 'Outlook signatures + PST files, Sticky Notes' $true),
    (New-Check 'bk.info' 'PC info, product key, BitLocker keys, IP settings' $true))
Add-Tiles $c @(
    @{ T = 'Browse...'; S = 'Pick the destination'; A = { $f = Select-Folder 'Where to save the backup (USB / other drive)'; if ($f) { Set-V 'bk.dest' (Join-Path $f ("TQNY-Backup\{0}_{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd'))) } } }
    @{ T = 'Start backup'; S = 'Copies; deletes nothing'; V = 'primary'; A = {
            $items = @(foreach ($k in 'files', 'bookmarks', 'wifi', 'drivers', 'apps', 'printers', 'extras', 'info') { if (Get-V "bk.$k") { $k } })
            $dest = Get-V 'bk.dest'; $u = Get-V 'bk.user'
            if (-not $dest) { Show-Msg 'Choose where to save the backup.' 'Warning'; return }
            if ($items.Count -eq 0) { Show-Msg 'Tick at least one item.' 'Warning'; return }
            if ($dest.StartsWith($env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Confirm-UI "The backup is going to $env:SystemDrive - the drive you would format." 'Continue anyway?' -Danger)) { return }
            }
            if (Confirm-UI "Back up $u to $dest ?" ("Items: " + ($items -join ', '))) {
                [void](Start-Task 'Backup' { Invoke-PcBackup $P } -Params @{ Dest = $dest; User = $u; Items = $items } -Admin -OnDone { param($r, $p) if ($p.Dest -and (Test-Path -LiteralPath $p.Dest)) { Open-Thing 'explorer.exe' "`"$($p.Dest)`"" } })
            }
        } }
)

$c = Add-Card $pg '2. After the format - restore' 'Pick the TQNY-Backup folder of this PC. Files are copied back without deleting anything that is already there.'
Add-Fields $c @(
    @{ L = 'Restore to user'; C = (New-Combo 'rs.user' -Wd 200) }
    @{ L = 'Backup folder'; C = (New-Input 'rs.src' '' 420) }
)
Add-Checks $c @(
    (New-Check 'rs.files' 'User files' $true), (New-Check 'rs.bookmarks' 'Browser bookmarks' $true), (New-Check 'rs.wifi' 'Wi-Fi networks' $true),
    (New-Check 'rs.drivers' 'Drivers' $true), (New-Check 'rs.apps' 'Reinstall apps (winget list)' $false), (New-Check 'rs.printers' 'Printers' $true),
    (New-Check 'rs.extras' 'Outlook / Sticky Notes' $true))
Add-Tiles $c @(
    @{ T = 'Browse...'; S = 'Pick the backup folder'; A = { $f = Select-Folder 'The TQNY-Backup folder of this PC'; if ($f) { Set-V 'rs.src' $f } } }
    @{ T = 'Start restore'; S = 'Copies back; deletes nothing'; V = 'primary'; A = {
            $items = @(foreach ($k in 'files', 'bookmarks', 'wifi', 'drivers', 'apps', 'printers', 'extras') { if (Get-V "rs.$k") { $k } })
            $src = Get-V 'rs.src'; $u = Get-V 'rs.user'
            if (-not $src -or -not (Test-Path -LiteralPath $src)) { Show-Msg 'Pick the backup folder.' 'Warning'; return }
            if (-not (Test-Path -LiteralPath (Join-Path $src 'TQNY-Backup.json'))) { if (-not (Confirm-UI 'This folder has no TQNY-Backup.json. Is it the right folder?')) { return } }
            if (Confirm-UI "Restore $src to user $u ?" ("Items: " + ($items -join ', '))) {
                [void](Start-Task 'Restore' { Invoke-PcRestore $P } -Params @{ Source = $src; User = $u; Items = $items } -Admin -OnDone { if ($sync.RebootNeeded) { Request-Restart 'Drivers or printers were restored.' } })
            }
        } }
)
$PageInit['backup'] = {
    $users = @(Get-UserProfiles)
    Set-ComboItems $UI['bk.user'] $users $env:USERNAME
    Set-ComboItems $UI['rs.user'] $users $env:USERNAME
    if (-not (Get-V 'bk.dest')) { Set-V 'bk.dest' (Get-UsbBackupRoot) }
}

# ---- Repair -------------------------------------------------------------------------------------
$pg = Add-Page 'repair' 'Repair' 'System files, disk, Windows components, crash investigation and special restarts.' 'E90F'

$c = Add-Card $pg 'Windows system files' 'Run DISM RestoreHealth first (repairs the source), then SFC (repairs the files).'
Add-Tiles $c @(
    @{ T = 'DISM + SFC (full repair)'; S = '20-40 minutes'; V = 'primary'; A = { if (Confirm-UI 'Run DISM RestoreHealth and then SFC?' 'Takes 20-40 minutes. The PC stays usable.') { [void](Start-Task 'DISM + SFC' { Invoke-Repair 'dism'; Invoke-Repair 'sfc' } -Admin) } } }
    @{ T = 'SFC /scannow'; S = 'Repair system files'; A = { [void](Start-Task 'SFC' { Invoke-Repair 'sfc' } -Admin) } }
    @{ T = 'DISM RestoreHealth'; S = 'Repair the Windows image'; A = { [void](Start-Task 'DISM RestoreHealth' { Invoke-Repair 'dism' } -Admin) } }
    @{ T = 'DISM CheckHealth'; S = 'Quick read-only check'; A = { [void](Start-Task 'DISM CheckHealth' { Invoke-Repair 'dism-check' } -Admin) } }
    @{ T = 'DISM ScanHealth'; S = 'Deeper read-only check'; A = { [void](Start-Task 'DISM ScanHealth' { Invoke-Repair 'dism-scan' } -Admin) } }
)

$c = Add-Card $pg 'Disk'
Add-Tiles $c @(
    @{ T = 'Check disk (online)'; S = 'No restart needed'; A = { [void](Start-Task 'Check disk' { Invoke-Repair 'chkdsk-scan' } -Admin) } }
    @{ T = 'Schedule full disk repair'; S = 'chkdsk /f /r at next restart'; V = 'danger'; A = { if (Confirm-UI "Schedule chkdsk /f /r on $env:SystemDrive for the next restart?" 'It runs before Windows starts and can take over an hour. Do not switch the PC off during it.' -Danger) { [void](Start-Task 'Schedule chkdsk' { Invoke-Repair 'chkdsk-fix' } -Admin) } } }
    @{ T = 'Optimise drives'; S = 'TRIM SSDs, defrag HDDs'; A = { [void](Start-Task 'Optimise drives' { Invoke-OptimizeDrives } -Admin) } }
    @{ T = 'Disk Management'; S = 'diskmgmt.msc'; A = { Open-Thing 'diskmgmt.msc' } }
)

$c = Add-Card $pg 'Windows components'
Add-Tiles $c @(
    @{ T = 'Reset Windows Update'; S = 'Stuck or failing updates'; A = { if (Confirm-UI 'Reset the Windows Update components?') { [void](Start-Task 'Reset Windows Update' { Reset-WindowsUpdate } -Admin) } } }
    @{ T = 'Reset network stack'; S = 'Winsock + TCP/IP, restart'; V = 'danger'; A = { if (Confirm-UI 'Reset Winsock and TCP/IP?' 'A restart is needed.' -Danger) { [void](Start-Task 'Reset network stack' { Invoke-NetRepair @('stack') } -Admin -OnDone { Request-Restart 'The network stack was reset.' }) } } }
    @{ T = 'Restart File Explorer'; S = 'Frozen taskbar / desktop'; A = { [void](Start-Task 'Restart Explorer' { Invoke-Repair 'explorer' }) } }
    @{ T = 'Rebuild icon cache'; S = 'Blank or wrong icons'; A = { [void](Start-Task 'Icon cache' { Invoke-Repair 'icons' }) } }
    @{ T = 'Repair Start menu'; S = 'Start / search not opening'; A = { [void](Start-Task 'Start menu' { Invoke-Repair 'startmenu' } -Admin) } }
    @{ T = 'Reset Store cache'; S = 'wsreset'; A = { [void](Start-Task 'Store reset' { Invoke-Repair 'store' }) } }
    @{ T = 'Repair Windows Time'; S = 'Clock keeps drifting'; A = { [void](Start-Task 'Repair time' { Invoke-Repair 'time' } -Admin) } }
    @{ T = 'Clear stuck print jobs'; S = 'Spooler reset'; A = { [void](Start-Task 'Clear print queue' { Restart-Spooler $true } -Admin) } }
)

$c = Add-Card $pg 'Investigate - read only'
Add-Tiles $c @(
    @{ T = 'Recent errors'; S = 'System log, last 7 days, grouped'; A = { [void](Start-Task 'Recent errors' { Invoke-Repair 'events' }) } }
    @{ T = 'Blue screens'; S = 'Crash dumps and BSOD events'; A = { [void](Start-Task 'Blue screens' { Invoke-Repair 'bsod' } -Admin) } }
    @{ T = 'Health check'; S = 'Disk, updates, antivirus...'; A = { [void](Start-Task 'Health check' { Invoke-HealthCheck }) } }
    @{ T = 'Reliability history'; S = 'Windows timeline of problems'; A = { Open-Thing 'perfmon.exe' '/rel' } }
    @{ T = 'Event Viewer'; S = 'eventvwr.msc'; A = { Open-Thing 'eventvwr.msc' } }
)

$c = Add-Card $pg 'Restart options'
Add-Tiles $c @(
    @{ T = 'Restart now'; S = 'In 5 seconds'; A = { if (Confirm-UI 'Restart the PC now?') { [void](Start-Task 'Restart' { Invoke-RestartMode 'now' } -Admin) } } }
    @{ T = 'Restart into BIOS / UEFI'; S = 'No hunting for F2 / Del'; A = { if (Confirm-UI 'Restart straight into the BIOS / UEFI setup?') { [void](Start-Task 'Restart to BIOS' { Invoke-RestartMode 'bios' } -Admin) } } }
    @{ T = 'Advanced startup'; S = 'Recovery, startup repair, USB boot'; A = { if (Confirm-UI 'Restart into the Windows recovery options?') { [void](Start-Task 'Advanced startup' { Invoke-RestartMode 'advanced' } -Admin) } } }
    @{ T = 'Next start in Safe Mode'; S = 'Stays until you leave it'; V = 'danger'; A = { if (Confirm-UI 'Make the next start Safe Mode?' 'Run this tool again in Safe Mode and use "Leave Safe Mode" when done.' -Danger) { [void](Start-Task 'Safe Mode' { Invoke-RestartMode 'safe' } -Admin) } } }
    @{ T = 'Leave Safe Mode'; S = 'Normal start next time'; A = { [void](Start-Task 'Leave Safe Mode' { Invoke-RestartMode 'unsafe' } -Admin) } }
    @{ T = 'Memory test'; S = 'Windows Memory Diagnostic'; A = { Open-Thing 'mdsched.exe' } }
)

# ---- Cleanup ----------------------------------------------------------------------------------
$pg = Add-Page 'cleanup' 'Cleanup' 'Free disk space and speed things up. Shows how much was freed.' 'E74D'

$c = Add-Card $pg 'Free up space'
Add-Checks $c @(
    (New-Check 'cl.temp' 'Temp files (user + Windows)' $true), (New-Check 'cl.wu' 'Windows Update download cache' $true),
    (New-Check 'cl.extra' 'Prefetch, thumbnails, delivery cache, old logs' $true), (New-Check 'cl.diskcleanup' 'Windows Disk Cleanup (all safe options)' $false),
    (New-Check 'cl.winsxs' 'Component store (WinSxS) - slow' $false), (New-Check 'cl.bin' 'Empty the Recycle Bin - PERMANENT' $false))
Add-Tiles $c @(
    @{ T = 'Clean selected'; S = 'Files in use are skipped'; V = 'primary'; A = {
            $w2 = @(foreach ($k in 'temp', 'wu', 'extra', 'diskcleanup', 'winsxs', 'bin') { if (Get-V "cl.$k") { $k } })
            if ($w2.Count -eq 0) { Show-Msg 'Tick at least one item.' 'Warning'; return }
            $warn = if ($w2 -contains 'bin') { 'The Recycle Bin is emptied PERMANENTLY.' } else { '' }
            if (Confirm-UI "Clean: $($w2 -join ', ') ?" $warn -Danger:($w2 -contains 'bin')) { [void](Start-Task 'Cleanup' { Invoke-Cleanup $P.W } -Params @{ W = $w2 } -Admin) }
        } }
    @{ T = 'Storage settings'; S = 'Windows Storage Sense'; A = { Open-Thing 'ms-settings:storagesense' } }
)

$c = Add-Card $pg 'Find what uses space and slows the PC'
Add-Tiles $c @(
    @{ T = 'Biggest files'; S = 'Top 25 under C:\Users'; A = { [void](Start-Task 'Biggest files' { Show-BigFiles }) } }
    @{ T = 'Startup apps'; S = 'What starts with Windows'; A = { [void](Start-Task 'Startup apps' { Show-StartupApps }) } }
    @{ T = 'Task Manager startup'; S = 'Disable startup apps'; A = { Open-Thing 'taskmgr.exe' '/0 /startup' } }
    @{ T = 'Optimise drives'; S = 'TRIM / defrag'; A = { [void](Start-Task 'Optimise drives' { Invoke-OptimizeDrives } -Admin) } }
)

# ---- Reports ----------------------------------------------------------------------------------
Add-NavGroup 'Info'
$pg = Add-Page 'reports' 'Reports' 'The customer handover sheet and the information reports.' 'E9D9'

$c = Add-Card $pg 'Customer handover sheet' 'A printable HTML sheet (plus a .txt copy) with your company details, the PC spec, the network as handed over, and every change this tool made in this session.'
Add-Fields $c @(
    @{ L = 'Customer / company'; C = (New-Input 'ho.customer' '' 260) }
    @{ L = 'Contact (name / phone)'; C = (New-Input 'ho.contact' '' 220) }
)
Add-Fields $c @(@{ L = 'Notes for the customer'; C = (New-Input 'ho.notes' '' 640 -Multi) })
Add-Tiles $c @(
    @{ T = 'Write handover sheet'; S = 'Opens it in the browser to print'; V = 'primary'; A = {
            [void](Start-Task 'Handover sheet' { [void](New-HandoverReport -Customer $P.Cu -Contact $P.Co -Notes $P.N -OldName $Facts.Name) } -Params @{ Cu = (Get-V 'ho.customer'); Co = (Get-V 'ho.contact'); N = (Get-V 'ho.notes') })
        } }
    @{ T = 'Work done this session'; S = 'What goes on the sheet'; A = { Say ''; Say '=== Work done this session ===' 'head'; if ($sync.Done.Count) { foreach ($x in $sync.Done) { Say "  - $x" } } else { Say '  (nothing changed yet)' 'dim' } } }
    @{ T = 'Open handover folder'; S = ''; A = { $d = Join-Path $Cfg.DataDir 'handover'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Open-Thing 'explorer.exe' "`"$d`"" } }
)

$c = Add-Card $pg 'Information'
Add-Tiles $c @(
    @{ T = 'System information'; S = 'Full specification'; A = { [void](Start-Task 'System information' { Show-SystemSpec }) } }
    @{ T = 'Health check'; S = 'Read only'; A = { [void](Start-Task 'Health check' { Invoke-HealthCheck }) } }
    @{ T = 'Battery report'; S = 'Laptop battery wear'; A = { [void](Start-Task 'Battery report' { New-BatteryReport } -Admin) } }
    @{ T = 'Installed programs'; S = 'Save as CSV'; A = { $f = Select-File 'CSV (*.csv)|*.csv' -Save -Name "programs-$($Facts.Name).csv"; if ($f) { [void](Start-Task 'Installed programs' { [void](Export-InstalledPrograms $P.F) } -Params @{ F = $f }) } } }
    @{ T = 'Open logs folder'; S = 'Every session is logged'; A = { Open-Thing 'explorer.exe' "`"$(Join-Path $Cfg.DataDir 'logs')`"" } }
    @{ T = 'msinfo32'; S = 'Windows System Information'; A = { Open-Thing 'msinfo32.exe' } }
)

# ---- Tools ------------------------------------------------------------------------------------
$pg = Add-Page 'tools' 'Tools' 'One click to the Windows admin consoles, plus a few Sysinternals tools downloaded on demand.' 'E756'

$c = Add-Card $pg 'Windows admin tools'
$toolList = @(
    @('Device Manager', 'devmgmt.msc', ''), @('Disk Management', 'diskmgmt.msc', ''), @('Computer Management', 'compmgmt.msc', ''),
    @('Services', 'services.msc', ''), @('Event Viewer', 'eventvwr.msc', ''), @('Task Manager', 'taskmgr.exe', ''),
    @('Control Panel', 'control.exe', ''), @('Programs and Features', 'appwiz.cpl', ''), @('Network Connections', 'ncpa.cpl', ''),
    @('System Properties', 'sysdm.cpl', ''), @('Firewall (advanced)', 'wf.msc', ''), @('Registry Editor', 'regedit.exe', ''),
    @('Group Policy', 'gpedit.msc', ''), @('System Configuration', 'msconfig.exe', ''), @('Resource Monitor', 'resmon.exe', ''),
    @('Local Users and Groups', 'lusrmgr.msc', ''), @('User Accounts', 'netplwiz.exe', ''), @('Credential Manager', 'control.exe', '/name Microsoft.CredentialManager'),
    @('Shared Folders', 'fsmgmt.msc', ''), @('Power Options', 'powercfg.cpl', ''), @('Sound', 'mmsys.cpl', ''),
    @('Display', 'ms-settings:display', ''), @('Windows Security', 'windowsdefender:', ''), @('Command Prompt (admin)', 'cmd.exe', ''),
    @('PowerShell (admin)', 'powershell.exe', '-NoExit -Command Set-Location ~'), @('Windows Update', 'ms-settings:windowsupdate', ''), @('System Information', 'msinfo32.exe', '')
)
$wrapT = New-Object Windows.Controls.WrapPanel
$wrapT.Margin = Get-Thick 0 10 0 0
foreach ($t in $toolList) {
    $btn = New-Tile -T $t[0] -S $t[1] -Wd 200 -A $null
    $btn.CommandParameter = $null
    $btn.DataContext = @($t[1], $t[2])
    $btn.MinHeight = 52
    $btn.Add_Click({ $x = $this.DataContext; Open-Thing $x[0] $x[1] })
    [void]$wrapT.Children.Add($btn)
}
[void]$c.Children.Add($wrapT)

$c = Add-Card $pg 'Sysinternals (Microsoft)' 'Downloaded from live.sysinternals.com into the data folder the first time, then run.'
Add-Tiles $c @(
    @{ T = 'Autoruns'; S = 'Everything that starts automatically'; A = { [void](Start-Task 'Autoruns' { Start-Sysinternals 'Autoruns64.exe' }) } }
    @{ T = 'Process Explorer'; S = 'Task Manager on steroids'; A = { [void](Start-Task 'Process Explorer' { Start-Sysinternals 'procexp64.exe' }) } }
    @{ T = 'TCPView'; S = 'Every network connection'; A = { [void](Start-Task 'TCPView' { Start-Sysinternals 'tcpview64.exe' }) } }
)

$c = Add-Card $pg 'Classic console tool' 'The v3.2 cmd menu is kept as TQNY-Classic.bat for scripted use (/apply, /list, /release, /prefix:, /setname:, /site:, /db:).'
Add-Tiles $c @(@{ T = 'Open the classic menu'; S = 'TQNY-Classic.bat'; A = {
            $b = Join-Path $Cfg.ScriptDir 'TQNY-Classic.bat'
            if (Test-Path -LiteralPath $b) { Open-Thing 'cmd.exe' "/c `"`"$b`" /menu`"" } else { Show-Msg 'TQNY-Classic.bat is not next to this tool (it is not included in the internet launcher).' 'Warning' }
        } })

# ---- Names & settings -------------------------------------------------------------------------
$pg = Add-Page 'settings' 'Names and settings' 'The name registry, the technician details and where this tool keeps its files.' 'E713'

$c = Add-Card $pg 'Name registry' 'TQNY-Names.csv records every name ever handed out, per prefix. Shared with TQNY-Classic.bat. Put it on a network share when two technicians work at once - an atomic lock stops both claiming the same number.'
Add-Note $c '' '#C9D3DF' 'set.regstatus'
Add-Tiles $c @(
    @{ T = 'Show all names'; S = 'Every row in the registry'; A = { [void](Start-Task 'Name registry' { Show-Registry }) } }
    @{ T = "Release this PC's number"; S = 'Frees the number; does not rename'; V = 'danger'; A = { if (Confirm-UI "Release $($Facts.Name)'s number in the registry?" 'The computer name itself is not changed.') { [void](Start-Task 'Release number' { Invoke-ReleaseNumber }) } } }
    @{ T = 'Open the CSV'; S = 'In Excel / Notepad'; A = { if (Test-Path -LiteralPath $Cfg.DbFile) { Open-Thing $Cfg.DbFile } else { Show-Msg 'The registry file does not exist yet. It is created on the first rename.' } } }
)
Add-Fields $c @(
    @{ L = 'Name prefix (PREFIX-NN)'; C = (New-Input 'set.prefix' $Cfg.Prefix 140 'Letters, digits and hyphens, 12 characters max. Each prefix numbers separately.') }
    @{ L = 'Registry file'; C = (New-Input 'set.db' $Cfg.DbFile 460) }
)
Add-Tiles $c @(
    @{ T = 'Use this prefix'; S = 'e.g. ACME gives ACME-01'; A = {
            $np = (Get-V 'set.prefix').Trim().TrimEnd('-')
            $bad = Test-Prefix $np
            if ($bad) { Show-Msg $bad 'Warning'; Set-V 'set.prefix' $Cfg.Prefix; return }
            $Cfg.Prefix = $np; Save-Settings; Update-SettingsStatus
            Say "  Prefix is now $np. Names will look like $np-01." 'ok'
        } }
    @{ T = 'Browse...'; S = 'Pick or create the CSV'; A = { $f = Select-File 'Name registry (*.csv)|*.csv' -Save -Name 'TQNY-Names.csv' -Dir (Split-Path $Cfg.DbFile); if ($f) { Set-V 'set.db' $f } } }
    @{ T = 'Use this registry file'; S = 'Also enables renaming in internet mode'; A = {
            $db = Get-V 'set.db'
            if (-not $db) { return }
            $dir = Split-Path -Parent $db
            if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { Show-Msg "The folder $dir does not exist." 'Warning'; return }
            $Cfg.DbFile = $db; $Cfg.DbExplicit = $true; Save-Settings; Update-SettingsStatus; Update-Banner
            Say "  Registry file is now $db" 'ok'
        } }
)

$c = Add-Card $pg 'Technician'
Add-Fields $c @(
    @{ L = 'Technician name (on the handover sheet)'; C = (New-Input 'set.tech' $Cfg.Tech 220) }
    @{ L = 'Site code'; C = (New-Input 'set.site' $(if ($Cfg.Site -ne '-') { $Cfg.Site } else { '' }) 120) }
)
Add-Tiles $c @(@{ T = 'Save'; S = 'Remembered next time'; V = 'primary'; A = {
            $t = Get-V 'set.tech'; if ($t) { $Cfg.Tech = $t -replace ',', ' ' }
            $s = Get-V 'set.site'; $Cfg.Site = if ($s) { $s -replace ',', ' ' } else { '-' }
            Save-Settings; Say '  Settings saved.' 'ok'
        } })

$c = Add-Card $pg 'About'
Add-Note $c '' '#C9D3DF' 'set.about'
Add-Tiles $c @(
    @{ T = 'Open data folder'; S = 'Logs, handover sheets, presets'; A = { New-Item -ItemType Directory -Path $Cfg.DataDir -Force | Out-Null; Open-Thing 'explorer.exe' "`"$($Cfg.DataDir)`"" } }
    @{ T = $Cfg.Company.Site; S = 'Company website'; A = { Open-Thing ('https://' + $Cfg.Company.Site) } }
    @{ T = $Cfg.Company.Store; S = 'Genuine licences'; A = { Open-Thing ('https://' + $Cfg.Company.Store) } }
)

function Save-Settings {
    try {
        New-Item -ItemType Directory -Path $Cfg.DataDir -Force | Out-Null
        $o = [ordered]@{ Tech = $Cfg.Tech; Site = $Cfg.Site; Prefix = $Cfg.Prefix; TZ = $Cfg.TZ }
        if (-not $Cfg.Remote) { $o.DbFile = $Cfg.DbFile }
        $o | ConvertTo-Json | Set-Content -LiteralPath $Cfg.SettingsFile -Encoding UTF8
    } catch { Say "  Could not save settings: $($_.Exception.Message)" 'warn' }
}
function Update-SettingsStatus {
    $UI['set.regstatus'].Text = "Prefix: $($Cfg.Prefix)    Registry: $($Cfg.DbFile)" + $(if (Test-Path -LiteralPath $Cfg.DbFile) { "    ($(@(Get-RegRows).Count) rows)" } else { '    (not created yet)' })
}
$PageShow['settings'] = {
    Update-SettingsStatus
    $co = $Cfg.Company
    $UI['set.about'].Text = "TQNY IT Setup v$($Cfg.Version)`n$($co.Name)`n$($co.Site)   $($co.Store)   $($co.CR)   $($co.Maroof)`n$($co.Mail)   $($co.Phone)`n`nData folder: $($Cfg.DataDir)`nThis session's log: $($State.LogFile)"
}


# ===========================================================================
#  START
# ===========================================================================
$Ctl.TxtVersion.Text = "IT Setup  v$($Cfg.Version)"
$Ctl.TxtCompany.Text = "$($Cfg.Company.Site)`n$($Cfg.Company.CR)  |  $($Cfg.Company.Maroof)"
if ($Cfg.IsAdmin) {
    $Ctl.AdminText.Text = 'Administrator'
} else {
    $Ctl.AdminText.Text = 'Read-only mode'
    $Ctl.AdminText.Foreground = $Brush.warn
    $Ctl.AdminChip.Background = Get-Brush '#2D2410'
}

[void](New-Chip $Facts.Name '#E6EDF3' '#161D26' 'chip.pc')
$UI['chip.pc'].ToolTip = "$($Facts.Manufacturer) $($Facts.ModelRaw)"
$rc = New-Chip 'Restart needed' '#FFD27A' '#2D2410' 'chip.reboot'
$rc.Visibility = 'Collapsed'
$rc.Cursor = [Windows.Input.Cursors]::Hand
$rc.ToolTip = 'Click to restart the PC'
$rc.Add_MouseLeftButtonUp({ Request-Restart 'A restart is needed to finish some changes.' })
Update-Banner

# Session log: one file per run, like v3.x
try {
    $logDir = Join-Path $Cfg.DataDir 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $State.LogFile = Join-Path $logDir ("{0}-{1}.log" -f $Facts.Name, (Get-Stamp))
    [IO.File]::WriteAllText($State.LogFile, ("TQNY-Setup v{0}  run {1} UTC  by {2}  admin={3}`r`n" -f $Cfg.Version, (Get-UtcNow), $Cfg.Tech, $Cfg.IsAdmin))
} catch { $State.LogFile = $null }

$Ctl.NavScroll.Add_PreviewMouseWheel({ param($s, $e) $s.ScrollToVerticalOffset($s.VerticalOffset - $e.Delta); $e.Handled = $true })
$Ctl.BtnStop.Add_Click({ Stop-Task })
$Ctl.BtnClear.Add_Click({ $State.Doc.Blocks.Clear() })
$Ctl.BtnCopy.Add_Click({
        $r = New-Object Windows.Documents.TextRange($State.Doc.ContentStart, $State.Doc.ContentEnd)
        try { [Windows.Clipboard]::SetText($r.Text); Say '  Log copied to the clipboard.' 'dim' } catch { Say '  Could not use the clipboard.' 'warn' }
    })
$Ctl.BtnSave.Add_Click({
        $f = Select-File 'Text file (*.txt)|*.txt' -Save -Name ("TQNY-log-{0}-{1}.txt" -f $Facts.Name, (Get-Stamp))
        if ($f) {
            $r = New-Object Windows.Documents.TextRange($State.Doc.ContentStart, $State.Doc.ContentEnd)
            [IO.File]::WriteAllText($f, $r.Text, (New-Object System.Text.UTF8Encoding $true))
            Say "  Log saved: $f" 'ok'
        }
    })
$Ctl.BtnLogs.Add_Click({ $d = Join-Path $Cfg.DataDir 'logs'; New-Item -ItemType Directory -Path $d -Force | Out-Null; Open-Thing 'explorer.exe' "`"$d`"" })

[void]$StartMarks.Add("pages {0:N1}s" -f $StartClock.Elapsed.TotalSeconds)

# Welcome
Say "TQNY IT Setup v$($Cfg.Version)" 'head'
Say "  $($Cfg.Company.Name)" 'dim'
Say ("  This PC : {0}   {1} {2}" -f $Facts.Name, $Facts.Manufacturer, $Facts.ModelRaw)
Say ("  Mode    : {0}" -f $(if ($Cfg.IsAdmin) { 'Administrator - changes are allowed, each one is confirmed first' } else { 'READ-ONLY - start again as Administrator to change things' })) $(if ($Cfg.IsAdmin) { 'ok' } else { 'warn' })
$g0 = Get-RenameGuard
if ($g0.Blocked) { Say "  Rename  : blocked - $($g0.Reason)" 'warn' }
Say "  Data    : $($Cfg.DataDir)" 'dim'
Say '  Pick a section on the left. Nothing changes until you confirm.' 'dim'

# Dark title bar on Windows 10 20H1+ / Windows 11 (helper compiled in the background).
function Set-DarkTitleBar {
    try {
        if (-not ('TQNY.Dwm' -as [type]) -and $DwmJob) { [void]$DwmJob.EndInvoke($DwmHandle) }
        if (-not ('TQNY.Dwm' -as [type])) { return }
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        $on = 1
        if ([TQNY.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4) -ne 0) { [void][TQNY.Dwm]::DwmSetWindowAttribute($hwnd, 19, [ref]$on, 4) }
    } catch { }
}
$Window.Add_SourceInitialized({ Set-DarkTitleBar })

$Window.Add_Loaded({
        $Timer.Start()
        Show-Page 'home'
        Update-Dashboard
    })
$Window.Add_ContentRendered({
        [void]$StartMarks.Add("shown {0:N1}s" -f $StartClock.Elapsed.TotalSeconds)
        Say ("  Started in {0:N1} s  ({1})" -f $StartClock.Elapsed.TotalSeconds, ($StartMarks -join ', ')) 'dim'
    })

$Window.Add_Closing({
        param($s, $e)
        $State.Pending = $null
        if ($State.Job -and $State.Job.Silent) { $State.ClosingWithJob = $true; Stop-Task }
        elseif ($State.Job) {
            if (Confirm-UI "'$($State.Job.Name)' is still running." 'Stop it and close TQNY IT Setup?' -Danger) { $State.ClosingWithJob = $true; Stop-Task }
            else { $e.Cancel = $true }
        }
    })

$Window.Add_Closed({
        $Timer.Stop()
        Invoke-DrainLog 100000
        Write-LogFile
        if (-not $State.ClosingWithJob) { try { $Runner.Close(); $Runner.Dispose() } catch { } }
        Remove-Item -LiteralPath (Join-Path $env:ProgramData 'TQNY-Setup\tmp') -Recurse -Force -ErrorAction SilentlyContinue
    })

[void]$Window.ShowDialog()

# A job that was stopped on close may still hold its thread; do not hang the exit.
if ($State.ClosingWithJob) { [Environment]::Exit(0) }

} catch {
    $msg = "TQNY IT Setup hit an error and has to close.`n`n$($_.Exception.Message)`n`nLine $($_.InvocationInfo.ScriptLineNumber): $(([string]$_.InvocationInfo.Line).Trim())"
    try { Set-Content -LiteralPath (Join-Path $env:TEMP 'TQNY-Setup-error.txt') -Value $msg } catch { }
    [void][System.Windows.MessageBox]::Show($msg, 'TQNY IT Setup', 'OK', 'Error')
}
