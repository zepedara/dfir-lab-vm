# DFIR VM repair: install .NET + Python (clean) + the missing forensic tools.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m){ Write-Host ("==== " + (Get-Date -Format o) + "  " + $m + " ====") }

# 1) .NET 9 Desktop Runtime (Eric Zimmerman tools need it)
Say 'Installing .NET 9 Desktop Runtime'
$dotnetOk = $false
if (Get-Command winget -ErrorAction SilentlyContinue) {
    cmd /c "winget install --id Microsoft.DotNet.DesktopRuntime.9 -e --silent --accept-source-agreements --accept-package-agreements" 2>&1 | Out-Null
    if (Test-Path 'C:\Program Files\dotnet\dotnet.exe') { $dotnetOk = $true }
}
if (-not $dotnetOk) {
    try {
        $d = Join-Path $env:TEMP 'dotnet-install.ps1'
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $d -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $d -Runtime windowsdesktop -Channel 9.0 -InstallDir 'C:\Program Files\dotnet'
        $dotnetOk = $true
    } catch { Say ('dotnet error: ' + $_.Exception.Message) }
}
Say ('dotnet present: ' + (Test-Path 'C:\Program Files\dotnet\dotnet.exe'))

# 2) Python (clean reinstall - the prior one was corrupted)
Say 'Reinstalling Python 3.12 clean to C:\DFIR\Python'
Remove-Item 'C:\DFIR\Python' -Recurse -Force -ErrorAction SilentlyContinue
try {
    $pi = Join-Path $env:TEMP 'py-setup.exe'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' -OutFile $pi -UseBasicParsing
    Start-Process $pi -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_pip=1','TargetDir=C:\DFIR\Python' -Wait
} catch { Say ('python install error: ' + $_.Exception.Message) }
$py = 'C:\DFIR\Python\python.exe'
Say ('python present: ' + (Test-Path $py))

# 3) pip forensic tools (wheels; no build needed)
Say 'Installing Volatility3, capa, FLOSS, oletools, yara-python, windowsprefetch (pip)'
try {
    & $py -m ensurepip --upgrade 2>&1 | Out-Null
    & $py -m pip install --upgrade --no-warn-script-location pip 2>&1 | Out-Null
    & $py -m pip install --no-warn-script-location volatility3 capa flare-floss oletools yara-python windowsprefetch 2>&1 | ForEach-Object { Write-Host $_ }
} catch { Say ('pip error: ' + $_.Exception.Message) }

# 4) YARA CLI binary
Say 'Installing YARA CLI'
try {
    $yz = Join-Path $env:TEMP 'yara.zip'
    Invoke-WebRequest 'https://github.com/VirusTotal/yara/releases/download/v4.5.2/yara-v4.5.2-2326-win64.zip' -OutFile $yz -UseBasicParsing
    New-Item -ItemType Directory -Force 'C:\DFIR\tools\yara' | Out-Null
    Expand-Archive $yz -DestinationPath 'C:\DFIR\tools\yara' -Force
} catch { Say ('yara error: ' + $_.Exception.Message) }

# 5) RegRipper (+ a 'rip' launcher via Git perl)
Say 'Installing RegRipper'
try {
    $rz = Join-Path $env:TEMP 'rr.zip'
    Invoke-WebRequest 'https://github.com/keydet89/RegRipper3.0/archive/refs/heads/master.zip' -OutFile $rz -UseBasicParsing
    New-Item -ItemType Directory -Force 'C:\DFIR\tools\regripper' | Out-Null
    Expand-Archive $rz -DestinationPath 'C:\DFIR\tools\regripper' -Force
    $rrdir = (Get-ChildItem 'C:\DFIR\tools\regripper' -Directory | Select-Object -First 1).FullName
    $perl = 'C:\DFIR\Git\usr\bin\perl.exe'
    if ((Test-Path $perl) -and $rrdir) {
        $bat = "@echo off`r`n`"$perl`" `"$rrdir\rip.pl`" %*"
        Set-Content 'C:\DFIR\tools\regripper\rip.bat' $bat -Encoding ascii
    }
} catch { Say ('regripper error: ' + $_.Exception.Message) }

# 6) PATH (machine): python scripts + yara + regripper + dotnet
$add = 'C:\DFIR\Python','C:\DFIR\Python\Scripts','C:\DFIR\tools\yara','C:\DFIR\tools\regripper','C:\Program Files\dotnet'
$mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
foreach ($p in $add) { if ($mp -notlike "*$p*") { $mp = "$p;$mp" } }
[Environment]::SetEnvironmentVariable('PATH', $mp, 'Machine')
foreach ($p in $add) { if (($env:PATH -split ';') -notcontains $p) { $env:PATH = "$p;$env:PATH" } }
Say 'PATH updated'

# 7) report back
$rep = 'DFIR FIX RESULT ' + (Get-Date -Format o) + "`r`n"
foreach ($t in 'vol','capa','floss','olevba','yara','prefetch','rip','PECmd.exe','EvtxECmd.exe') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) { $rep += "[OK]      $t -> $($c.Source)`r`n" } else { $rep += "[MISSING] $t`r`n" }
}
$rep += '[dotnet] ' + (Test-Path 'C:\Program Files\dotnet\dotnet.exe') + "`r`n"
$rep | Out-File "$env:USERPROFILE\dfir-fix.txt" -Encoding ascii
try { Invoke-RestMethod -Uri 'https://ntfy.sh/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Title='DFIR fix result'; Tags='dfir_fix' } } catch {}
try { Invoke-RestMethod -Uri 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Authorization='Bearer tk_oa9v85p645zgm7n50l0ytdpekuyyv'; Title='DFIR fix result'; Tags='dfir_fix' } } catch {}
Write-Host $rep
Say 'FIX DONE - report sent to Rem'
