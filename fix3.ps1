# DFIR VM repair pass 3: install Python via the EMBEDDABLE zip (no installer) + pip tools.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m){ Write-Host ("==== " + (Get-Date -Format o) + "  " + $m + " ====") }
$rep = 'DFIR FIX3 ' + (Get-Date -Format o) + "`r`n"
function R($m){ $script:rep += ($m + "`r`n"); Write-Host $m }

$pdir = 'C:\DFIR\Python'
Say 'Installing embeddable Python (no installer) to C:\DFIR\Python'
try {
    Remove-Item $pdir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $pdir | Out-Null
    $z = Join-Path $env:TEMP 'pyembed.zip'
    Invoke-WebRequest 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip' -OutFile $z -UseBasicParsing
    Expand-Archive $z -DestinationPath $pdir -Force
    $pth = Get-ChildItem $pdir -Filter 'python*._pth' | Select-Object -First 1
    if ($pth) {
        (Get-Content $pth.FullName) -replace '^#\s*import site','import site' | Set-Content $pth.FullName
        Add-Content $pth.FullName "Lib\site-packages"
    }
    R ('embed python extracted: ' + (Test-Path "$pdir\python.exe"))
} catch { R ('embed error: ' + $_.Exception.Message) }

$py = "$pdir\python.exe"
if (Test-Path $py) {
    Say 'Bootstrapping pip (get-pip.py)'
    try {
        $gp = Join-Path $env:TEMP 'get-pip.py'
        Invoke-WebRequest 'https://bootstrap.pypa.io/get-pip.py' -OutFile $gp -UseBasicParsing
        & $py $gp --no-warn-script-location 2>&1 | Select-Object -Last 2 | ForEach-Object { R ('getpip: ' + $_) }
    } catch { R ('getpip error: ' + $_.Exception.Message) }
    Say 'pip install: volatility3 capa flare-floss oletools yara-python windowsprefetch'
    $out = & $py -m pip install --no-warn-script-location volatility3 capa flare-floss oletools yara-python windowsprefetch 2>&1
    R ('pip tail: ' + (($out | Select-Object -Last 4) -join ' || '))
    $mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
    foreach ($p in @($pdir, "$pdir\Scripts")) { if ($mp -notlike "*$p*") { $mp = "$p;$mp" }; if (($env:PATH -split ';') -notcontains $p) { $env:PATH = "$p;$env:PATH" } }
    [Environment]::SetEnvironmentVariable('PATH', $mp, 'Machine')
} else { R 'ERROR: embeddable python not present' }

foreach ($t in 'vol','capa','floss','olevba','prefetch') {
    $c = Get-Command $t -ErrorAction SilentlyContinue
    $disk = Test-Path "$pdir\Scripts\$t.exe"
    if ($c) { R "[OK]      $t -> $($c.Source)" } elseif ($disk) { R "[ONDISK]  $t -> $pdir\Scripts\$t.exe" } else { R "[MISSING] $t" }
}
try { Invoke-RestMethod -Uri 'https://ntfy.sh/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Title='DFIR fix3'; Tags='dfir_fix' } } catch {}
try { Invoke-RestMethod -Uri 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Authorization='Bearer tk_oa9v85p645zgm7n50l0ytdpekuyyv'; Title='DFIR fix3'; Tags='dfir_fix' } } catch {}
Write-Host $rep
Say 'FIX3 DONE - report sent to Rem'
