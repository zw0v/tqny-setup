# ===========================================================================
#  TQNY IT Setup - remote launcher
#
#  Run from any PC with internet:
#      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
#
#  It downloads TQNY-Setup.bat to a temp folder and opens the menu.
#
#  NOTE ON RENAMING: launched this way there is no name registry reachable,
#  so the tool will NOT rename a PC - it would be handing out a number it
#  cannot record, which is exactly how two machines end up with the same
#  name. The internet check and the network-visibility fix work normally.
#  To enable renaming, point it at a registry file you control:
#
#      $env:TQNY_DB = '\\server\share\TQNY-Names.csv'
#      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
# ===========================================================================

$ErrorActionPreference = 'Stop'

# Secret gist: not listed on the profile, not indexed, reachable only by link,
# and its raw URL needs no login so this one-liner works anywhere.
$GistId  = '6a91d906258ca360a88265b6dcd28ba6'
$RawBase = "https://gist.githubusercontent.com/zw0v/$GistId/raw"
$BatUrl  = "$RawBase/TQNY-Setup.bat"
# Helper scripts the .bat runs for the network and printer scans. They must land
# next to the .bat so its :find_helper can locate them.
$Helpers = 'scan-source.ps1', 'printer-scan-source.ps1'

Write-Host ''
Write-Host '  TQNY IT Setup - remote launcher' -ForegroundColor Cyan
Write-Host ''

# TLS 1.2 for older Windows PowerShell builds.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$dir = Join-Path $env:TEMP ('tqny-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$bat = Join-Path $dir 'TQNY-Setup.bat'

Write-Host "  Downloading ..." -ForegroundColor DarkGray
try {
    Invoke-WebRequest -Uri $BatUrl -OutFile $bat -UseBasicParsing
} catch {
    Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Check the internet connection on this PC and try again.' -ForegroundColor Red
    return
}

# A .bat needs CRLF or cmd jumps to the wrong lines. GitHub can serve LF.
$text = [System.IO.File]::ReadAllText($bat)
$text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
[System.IO.File]::WriteAllText($bat, $text, (New-Object System.Text.UTF8Encoding $false))

# Pull the scan helpers next to the .bat. A failure here is not fatal - the
# tool still runs, only the network/printer scan reports the helper is missing.
foreach ($h in $Helpers) {
    try { Invoke-WebRequest -Uri "$RawBase/$h" -OutFile (Join-Path $dir $h) -UseBasicParsing } catch {}
}

$argList = @('/remote')
if ($env:TQNY_DB) {
    $argList += "/db:$($env:TQNY_DB)"
    Write-Host "  Name registry: $($env:TQNY_DB)" -ForegroundColor DarkGray
} else {
    Write-Host '  No registry set, so renaming is disabled. See the note at the' -ForegroundColor Yellow
    Write-Host '  top of this launcher to enable it with $env:TQNY_DB.' -ForegroundColor Yellow
}
# /menu must come LAST: any switch otherwise routes past the menu into the
# scripted flow, and it has to follow /remote and /db so both are already set.
$argList += '/menu'
Write-Host ''

# Hand over to the batch menu in this same console.
& cmd.exe /c "`"$bat`"" @argList

try { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
