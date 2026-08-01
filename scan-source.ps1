# ===========================================================================
#  scan-source.ps1  -  the network scanner behind TQNY-Setup "Scan the network"
#
#  READ ONLY. It pings the local /24 and asks each live host for its name.
#  Nothing on the network is changed.
#
#  This file is the READABLE SOURCE. It is Base64-encoded into TQNY-Setup.bat
#  and run there with  powershell -EncodedCommand , which avoids having to
#  escape a raw NetBIOS packet and socket code inside a .bat. Re-encode after
#  editing by running push-tqny.bat (or the one-liner in its header).
#
#  Inputs, passed as environment variables by the .bat:
#     TQNY_SCAN_BASE    optional  first three octets, e.g. 192.168.1
#     TQNY_SCAN_PREFIX  optional  current naming prefix, e.g. TQNY
# ===========================================================================

$ErrorActionPreference = 'SilentlyContinue'

# --- work out which interface and subnet to scan -----------------------------
$adapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
           Sort-Object ifIndex | Select-Object -First 1
if (-not $adapter) {
    Write-Output 'NOSCAN=No connected physical network adapter. Cannot scan.'
    return
}
$cfg     = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
$localIP = $cfg.IPv4Address.IPAddress
if (-not $localIP) {
    Write-Output 'NOSCAN=This PC has no IPv4 address, so there is no network to scan.'
    return
}

$base = $env:TQNY_SCAN_BASE
if ([string]::IsNullOrWhiteSpace($base)) {
    $base = ($localIP -split '\.')[0..2] -join '.'
}
$base = $base.Trim().TrimEnd('.')

$prefix = $env:TQNY_SCAN_PREFIX
if ($prefix) { $prefix = $prefix.Trim() }

Write-Output "INFO=Scanning $base.1-254 from $localIP on $($adapter.Name)"

# --- 1. async ping sweep of the whole /24 (sub-second) -----------------------
$tasks = 1..254 | ForEach-Object {
    (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$base.$_", 700)
}
[System.Threading.Tasks.Task]::WaitAll($tasks)

$alive = @{}   # ip -> roundtrip ms
for ($i = 0; $i -lt 254; $i++) {
    $r = $tasks[$i].Result
    if ($r.Status -eq 'Success') { $alive["$base.$($i+1)"] = [int]$r.RoundtripTime }
}

if ($alive.Count -eq 0) {
    Write-Output "DONE=0"
    return
}

# --- 2. names via a NetBIOS node-status query, bound to the REAL nic ---------
# nbtstat.exe binds to the wrong adapter on any PC with VMware/VirtualBox, so we
# send the query ourselves from $localIP. One socket per host, each with an
# outstanding async receive, all awaited together with a hard 2.5 s cap: fast
# because the waits overlap, reliable because a reply is matched to its socket.
$names = @{}

# NetBIOS Node Status Request for the wildcard name '*'
$pkt = [byte[]]@(
    0xA1,0xA2, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00,
    0x20, 0x43,0x4B,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,
    0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,
    0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x41,0x00,
    0x00,0x21, 0x00,0x01)

$socks     = @()
$recvTasks = @{}
foreach ($ip in @($alive.Keys)) {
    try {
        $bindEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($localIP), 0)
        $u = New-Object System.Net.Sockets.UdpClient($bindEp)
        [void]$u.Send($pkt, $pkt.Length, $ip, 137)
        $recvTasks[$ip] = $u.ReceiveAsync()
        $socks += $u
    } catch {}
}
if ($recvTasks.Count -gt 0) {
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($recvTasks.Values), 2500) } catch {}
    foreach ($ip in @($recvTasks.Keys)) {
        $t = $recvTasks[$ip]
        if ($t.Status -ne 'RanToCompletion') { continue }
        $data = $t.Result.Buffer
        if (-not $data -or $data.Length -lt 57) { continue }
        $count = $data[56]
        for ($k = 0; $k -lt $count; $k++) {
            $off = 57 + ($k * 18)
            if ($off + 17 -ge $data.Length) { break }
            $suffix  = $data[$off + 15]
            $isGroup = ($data[$off + 16] -band 0x80) -ne 0    # G bit, MSB of flags
            if ($suffix -eq 0x00 -and -not $isGroup) {
                $nm = [System.Text.Encoding]::ASCII.GetString($data, $off, 15).Trim()
                if ($nm) { $names[$ip] = $nm }
                break
            }
        }
    }
}
foreach ($s in $socks) { try { $s.Close() } catch {} }

# --- 3. reverse DNS as a fallback name (for non-Windows hosts) ---------------
# Fired all at once and capped at 2 s total: a host with no PTR record makes a
# synchronous lookup block ~10 s, which would wreck the scan time. Whatever has
# not resolved when the cap hits is simply left without a name.
$dnsTasks = @{}
foreach ($ip in $alive.Keys) {
    if (-not $names.ContainsKey($ip)) {
        try { $dnsTasks[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch {}
    }
}
if ($dnsTasks.Count -gt 0) {
    try { [void][System.Threading.Tasks.Task]::WaitAll(@($dnsTasks.Values), 2000) } catch {}
    foreach ($ip in @($dnsTasks.Keys)) {
        $t = $dnsTasks[$ip]
        if ($t.Status -eq 'RanToCompletion' -and $t.Result.HostName) {
            $names[$ip] = ($t.Result.HostName -split '\.')[0]
        }
    }
}

# --- 4. MAC addresses from the ARP cache -------------------------------------
$macs = @{}
foreach ($line in (arp -a)) {
    if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9A-Fa-f-]{17})') {
        $macs[$matches[1]] = $matches[2].ToUpper()
    }
}

# --- 5. print the table ------------------------------------------------------
$rows = $alive.Keys | Sort-Object { [int]($_ -split '\.')[3] }
foreach ($ip in $rows) {
    $isSelf = ($ip -eq $localIP)
    $name   = if ($isSelf) { $env:COMPUTERNAME } elseif ($names[$ip]) { $names[$ip] } else { '-' }
    $mac    = if ($isSelf) { '(this pc)' } elseif ($macs[$ip]) { $macs[$ip] } else { '-' }
    $ms     = $alive[$ip]
    $tag    = ''
    if ($isSelf) { $tag = '<< THIS PC' }
    elseif ($prefix -and $name -like "$prefix-*") { $tag = "<< $prefix name in use" }
    Write-Output ("ROW={0,-15}|{1,-16}|{2,-17}|{3,5}|{4}" -f $ip, $name, $mac, $ms, $tag)
}
Write-Output "DONE=$($alive.Count)"
