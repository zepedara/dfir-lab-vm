# DFIR VM repair pass 2: get a REAL Python (bypass the Windows Store stub) + pip tools + yara.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m){ Write-Host ("==== " + (Get-Date -Format o) + "  " + $m + " ====") }

Say 'Locating or installing a REAL Python (not the Store stub)'
$py = $null
foreach ($c in 'C:\DFIR\Python\python.exe','C:\Program Files\Python312\python.exe','C:\Program Files\Python313\python.exe','C:\Program Files\Python311\python.exe') { if (Test-Path $c) { $py = $c; break } }
if (-not $py -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Say 'Installing Python via winget'
    cmd /c "winget install -e --id Python.Python.3.12 --scope machine --silent --accept-source-agreements --accept-package-agreements" 2>&1 | Out-Null
    foreach ($c in 'C:\Program Files\Python312\python.exe','C:\Program Files\Python313\python.exe') { if (Test-Path $c) { $py = $c; break } }
}
if (-not $py) {
    Say 'Installing Python via python.org'
    $pi = Join-Path $env:TEMP 'py2.exe'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe' -OutFile $pi -UseBasicParsing
    Start-Process $pi -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_pip=1','TargetDir=C:\DFIR\Python' -Wait
    if (Test-Path 'C:\DFIR\Python\python.exe') { $py = 'C:\DFIR\Python\python.exe' }
}
Say ('python = ' + $py)
if ($py) {
    $pydir = Split-Path $py
    Say 'pip: volatility3 capa flare-floss oletools yara-python windowsprefetch'
    & $py -m ensurepip --upgrade 2>&1 | Out-Null
    & $py -m pip install --upgrade pip 2>&1 | Out-Null
    & $py -m pip install --no-warn-script-location volatility3 capa flare-floss oletools yara-python windowsprefetch 2>&1 | ForEach-Object { Write-Host $_ }
    $mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
    foreach ($p in @($pydir, (Join-Path $pydir 'Scripts'))) { if ($mp -notlike "*$p*") { $mp = "$p;$mp" }; if (($env:PATH -split ';') -notcontains $p) { $env:PATH = "$p;$env:PATH" } }
    [Environment]::SetEnvironmentVariable('PATH', $mp, 'Machine')
} else { Say 'ERROR: could not obtain a real Python' }

if (-not (Get-Command yara -ErrorAction SilentlyContinue)) {
    Say 'Installing YARA CLI'
    try {
        $yz = Join-Path $env:TEMP 'yara.zip'
        Invoke-WebRequest 'https://github.com/VirusTotal/yara/releases/download/v4.5.2/yara-v4.5.2-2326-win64.zip' -OutFile $yz -UseBasicParsing
        New-Item -ItemType Directory -Force 'C:\DFIR\tools\yara' | Out-Null
        Expand-Archive $yz -DestinationPath 'C:\DFIR\tools\yara' -Force
        $mp = [Environment]::GetEnvironmentVariable('PATH','Machine'); if ($mp -notlike '*C:\DFIR\tools\yara*') { [Environment]::SetEnvironmentVariable('PATH','C:\DFIR\tools\yara;'+$mp,'Machine') }
        $env:PATH = 'C:\DFIR\tools\yara;' + $env:PATH
    } catch { Say ('yara error: ' + $_.Exception.Message) }
}

$rep = 'DFIR FIX2 RESULT ' + (Get-Date -Format o) + "`r`n"
foreach ($t in 'python','vol','capa','floss','olevba','yara','prefetch','rip','PECmd.exe') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    if ($c) { $rep += "[OK]      $t -> $($c.Source)`r`n" } else { $rep += "[MISSING] $t`r`n" }
}
$rep | Out-File "$env:USERPROFILE\dfir-fix2.txt" -Encoding ascii
try { Invoke-RestMethod -Uri 'https://ntfy.sh/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Title='DFIR fix2'; Tags='dfir_fix' } } catch {}
try { Invoke-RestMethod -Uri 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Authorization='Bearer tk_oa9v85p645zgm7n50l0ytdpekuyyv'; Title='DFIR fix2'; Tags='dfir_fix' } } catch {}
Write-Host $rep
Say 'FIX2 DONE - report sent to Rem'
