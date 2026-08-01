# ===========================================================================
#  printer-scan-source.ps1  -  find printers and scanners on the LAN
#
#  READ ONLY. Probes each live host for printer ports and asks printers their
#  model over SNMP; detects MFP scanners over eSCL. Nothing is changed.
#
#  Like scan-source.ps1 this is the readable source; it is Base64-encoded into
#  TQNY-Setup.bat and run with  powershell -EncodedCommand . Re-encode with
#  push-tqny.bat after editing.
#
#  Input env vars from the .bat:
#     TQNY_SCAN_BASE   optional  first three octets, e.g. 192.168.1
# ===========================================================================

$ErrorActionPreference = 'SilentlyContinue'

$adapter = Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' } |
           Sort-Object ifIndex | Select-Object -First 1
if (-not $adapter) { Write-Output 'NOSCAN=No connected network adapter.'; return }
$localIP = (Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex).IPv4Address.IPAddress
if (-not $localIP) { Write-Output 'NOSCAN=No IPv4 address.'; return }

$base = $env:TQNY_SCAN_BASE
if ([string]::IsNullOrWhiteSpace($base)) { $base = ($localIP -split '\.')[0..2] -join '.' }
$base = $base.Trim().TrimEnd('.')
Write-Output "INFO=Looking for printers and scanners on $base.1-254"

# --- 1. ping sweep -----------------------------------------------------------
$tasks = 1..254 | ForEach-Object {
    (New-Object System.Net.NetworkInformation.Ping).SendPingAsync("$base.$_", 700)
}
[System.Threading.Tasks.Task]::WaitAll($tasks)
$alive = for ($i = 0; $i -lt 254; $i++) { if ($tasks[$i].Result.Status -eq 'Success') { "$base.$($i+1)" } }
if (-not $alive) { Write-Output 'DONE=0'; return }

# --- 2. probe printer ports 9100 / 515 / 631 in parallel ---------------------
$portMap = @{ 9100 = 'RAW'; 515 = 'LPD'; 631 = 'IPP' }
$conns = @()
foreach ($ip in $alive) {
    foreach ($p in 9100, 515, 631) {
        $c = New-Object System.Net.Sockets.TcpClient
        $conns += [pscustomobject]@{ IP = $ip; Port = $p; Client = $c; Task = $c.ConnectAsync($ip, $p) }
    }
}
try { [void][System.Threading.Tasks.Task]::WaitAll(@($conns.Task), 1200) } catch {}
$proto = @{}   # ip -> list of protocol tags
foreach ($c in $conns) {
    if ($c.Task.Status -eq 'RanToCompletion' -and $c.Client.Connected) {
        if (-not $proto[$c.IP]) { $proto[$c.IP] = New-Object System.Collections.ArrayList }
        [void]$proto[$c.IP].Add($portMap[[int]$c.Port])
    }
    try { $c.Client.Close() } catch {}
}

# --- 3. SNMP GET sysDescr.0 for a model string -------------------------------
# Minimal ASN.1 builder (all our lengths are < 128, single-byte length form).
function TLV([int]$tag, [byte[]]$val) { ,([byte]$tag) + [byte]$val.Length + $val }
$oidSysDescr = [byte[]](0x2B,0x06,0x01,0x02,0x01,0x01,0x01,0x00)   # 1.3.6.1.2.1.1.1.0
$varbind = TLV 0x30 ((TLV 0x06 $oidSysDescr) + (TLV 0x05 @()))
$vblist  = TLV 0x30 $varbind
$pdu = TLV 0xA0 ((TLV 0x02 @(0x01)) + (TLV 0x02 @(0x00)) + (TLV 0x02 @(0x00)) + $vblist)
$community = [System.Text.Encoding]::ASCII.GetBytes('public')
$snmpPkt = TLV 0x30 ((TLV 0x02 @(0x00)) + (TLV 0x04 $community) + $pdu)

$models = @{}
$targets = @($alive | Where-Object { $proto[$_] })   # only hosts that look like printers
if ($targets.Count -gt 0) {
    $udpSocks = @()
    $rx = @{}
    foreach ($ip in $targets) {
        try {
            $bindEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($localIP), 0)
            $u = New-Object System.Net.Sockets.UdpClient($bindEp)
            [void]$u.Send($snmpPkt, $snmpPkt.Length, $ip, 161)
            $rx[$ip] = $u.ReceiveAsync()
            $udpSocks += $u
        } catch {}
    }
    if ($rx.Count -gt 0) {
        try { [void][System.Threading.Tasks.Task]::WaitAll(@($rx.Values), 1500) } catch {}
        foreach ($ip in @($rx.Keys)) {
            $t = $rx[$ip]
            if ($t.Status -ne 'RanToCompletion') { continue }
            $d = $t.Result.Buffer
            # find the request OID, then read the OCTET STRING value that follows
            for ($i = 0; $i -lt $d.Length - $oidSysDescr.Length - 2; $i++) {
                $match = $true
                for ($j = 0; $j -lt $oidSysDescr.Length; $j++) {
                    if ($d[$i + $j] -ne $oidSysDescr[$j]) { $match = $false; break }
                }
                if (-not $match) { continue }
                $vpos = $i + $oidSysDescr.Length
                if ($d[$vpos] -eq 0x04) {
                    $len = $d[$vpos + 1]; $start = $vpos + 2
                    if ($len -band 0x80) {           # long-form length
                        $n = $len -band 0x7F; $len = 0
                        for ($x = 0; $x -lt $n; $x++) { $len = ($len -shl 8) -bor $d[$vpos + 2 + $x] }
                        $start = $vpos + 2 + $n
                    }
                    if ($len -gt 0 -and $start + $len -le $d.Length) {
                        $s = [System.Text.Encoding]::ASCII.GetString($d, $start, [Math]::Min($len, 80))
                        $models[$ip] = ($s -replace '[\r\n]+', ' ').Trim()
                    }
                }
                break
            }
        }
    }
    foreach ($u in $udpSocks) { try { $u.Close() } catch {} }
}

# --- 4. eSCL scanner probe (MFPs) on port 80 ---------------------------------
foreach ($ip in $targets) {
    try {
        $req = [System.Net.HttpWebRequest]::Create("http://$ip/eSCL/ScannerCapabilities")
        $req.Timeout = 900; $req.Method = 'GET'
        $resp = $req.GetResponse()
        if ([int]$resp.StatusCode -eq 200) { [void]$proto[$ip].Add('eSCL') }
        $resp.Close()
    } catch {}
}

# --- 5. print the devices found ----------------------------------------------
$found = @($proto.Keys | Sort-Object { [int]($_ -split '\.')[3] })
foreach ($ip in $found) {
    $model = if ($models[$ip]) { $models[$ip] } else { '(model not reported)' }
    $tags  = ($proto[$ip] | Sort-Object -Unique) -join ','
    Write-Output ("DEV={0,-15}|{1,-38}|{2}" -f $ip, $model, $tags)
}
Write-Output "DONE=$($found.Count)"
