# ===========================================================================
#  TQNY IT Setup v4.0 - remote launcher
#
#  Run from any PC with internet:
#      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
#
#  It downloads the TQNY IT Setup app (TQNY-Setup.ps1) to a temp folder,
#  asks for Administrator once, and opens the app window. The temp folder is
#  removed when you close the app. Logs and handover sheets are kept in
#  C:\ProgramData\TQNY-Setup so they survive.
#
#  NOTE ON RENAMING: launched this way there is no name registry reachable,
#  so the app will NOT rename a PC - it would be handing out a number it
#  cannot record, which is how two machines end up with the same name.
#  Everything else works. To enable renaming, point it at a registry you control:
#
#      $env:TQNY_DB = '\\server\share\TQNY-Names.csv'
#      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
#
#  The old v3.2 console menu instead of the app:
#
#      $env:TQNY_CLASSIC = '1'
#      irm https://gist.githubusercontent.com/zw0v/6a91d906258ca360a88265b6dcd28ba6/raw/tqny.ps1 | iex
# ===========================================================================

$ErrorActionPreference = 'Stop'

# Secret gist: not listed on the profile, not indexed, reachable only by link,
# and its raw URL needs no login so this one-liner works anywhere.
$GistId  = '6a91d906258ca360a88265b6dcd28ba6'
$RawBase = "https://gist.githubusercontent.com/zw0v/$GistId/raw"

Write-Host ''
Write-Host '  TQNY IT Setup v4.0 - remote launcher' -ForegroundColor Cyan
Write-Host ''

# TLS 1.2 for older Windows PowerShell builds.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$dir = Join-Path $env:TEMP ('tqny-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null

function Get-TqnyFile([string]$Name) {
    $out = Join-Path $dir $Name
    Invoke-WebRequest -Uri "$RawBase/$Name" -OutFile $out -UseBasicParsing
    return $out
}

# ---- classic v3.2 console menu ------------------------------------------------
if ($env:TQNY_CLASSIC) {
    Write-Host '  Downloading the classic console tool ...' -ForegroundColor DarkGray
    try { $bat = Get-TqnyFile 'TQNY-Classic.bat' } catch {
        Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    # A .bat needs CRLF or cmd jumps to the wrong lines. GitHub can serve LF.
    $text = [System.IO.File]::ReadAllText($bat)
    $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"
    [System.IO.File]::WriteAllText($bat, $text, (New-Object System.Text.UTF8Encoding $false))
    foreach ($h in 'scan-source.ps1', 'printer-scan-source.ps1') { try { [void](Get-TqnyFile $h) } catch { } }
    $argList = @('/remote')
    if ($env:TQNY_DB) { $argList += "/db:$($env:TQNY_DB)" }
    $argList += '/menu'
    & cmd.exe /c "`"$bat`"" @argList
    try { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    return
}

# ---- the v4.0 app ---------------------------------------------------------------
Write-Host '  Downloading the app ...' -ForegroundColor DarkGray
try { $app = Get-TqnyFile 'TQNY-Setup.ps1' } catch {
    Write-Host "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '  Check the internet connection on this PC and try again.' -ForegroundColor Red
    return
}

$a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$app`"", '-Remote', '-NoElevate')
if ($env:TQNY_DB) {
    $a += @('-Db', "`"$($env:TQNY_DB)`"")
    Write-Host "  Name registry: $($env:TQNY_DB)" -ForegroundColor DarkGray
} else {
    Write-Host '  No name registry set, so renaming is disabled. See the note at the' -ForegroundColor Yellow
    Write-Host '  top of this launcher to enable it with $env:TQNY_DB.' -ForegroundColor Yellow
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host '  Opening TQNY IT Setup. This window waits until you close the app.' -ForegroundColor DarkGray
Write-Host ''
try {
    if ($isAdmin) { Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait }
    else { Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs -Wait }
} catch {
    Write-Host '  Administrator was declined - opening in read-only mode.' -ForegroundColor Yellow
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Wait
}

try { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
Write-Host '  Closed. Logs and handover sheets: C:\ProgramData\TQNY-Setup' -ForegroundColor DarkGray
