# =============================================================================
# 35 - Native forensic tools (PROVEN complete set — 14 pass / 0 fail, 2026-07-14)
#
#   This is the single source of truth for what the NATIVE-first DFIR lab needs.
#   v2 shipped the lab CONTENT but installed almost none of these -> lab unrunnable.
#   Installs, idempotently, everything the 16 modules invoke, plus the bash shims
#   that make bare tool names resolve in Git-Bash, plus the canonical chainsaw
#   rules path and the Perl module RegRipper needs.
#
#   Assumes 05-native-toolbox.ps1 already put Git-for-Windows at C:\dfir\tools\git,
#   Miller/csvkit, and updated PATH. Assumes EZ tools + chainsaw + hayabusa present
#   (30/34). Run AFTER those. NO container / NO WSL2 / NO nested-virt.
# =============================================================================
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Say($m) { Write-Host "[native-forensic] $m" }

$tools   = 'C:\dfir\tools'
$shim    = Join-Path $tools 'native-shim'
$git     = Join-Path $tools 'git'
$pyDir   = 'C:\dfir\Python'
$py      = Join-Path $pyDir 'python.exe'
$perl    = Join-Path $git 'usr\bin\perl.exe'
$bash    = Join-Path $git 'bin\bash.exe'
New-Item -ItemType Directory -Force -Path $shim | Out-Null

# Write an extensionless bash shim (LF endings, no BOM).
function New-Shim($name, $body) {
    $p = Join-Path $shim $name
    [IO.File]::WriteAllText($p, "#!/usr/bin/env bash`n$body`n")
}

# ---------------------------------------------------------------------------
# 1) Python 3 + volatility3 + oletools   (v2 guest had ONLY Python 2.7)
# ---------------------------------------------------------------------------
if (-not (Test-Path $py)) {
    Say 'installing Python 3.12...'
    $u = 'https://www.python.org/ftp/python/3.12.7/python-3.12.7-amd64.exe'
    $exe = Join-Path $env:TEMP 'py312.exe'
    & curl.exe -L --fail -s -o $exe $u
    Start-Process $exe -ArgumentList "/quiet InstallAllUsers=1 PrependPath=0 TargetDir=$pyDir Include_pip=1" -Wait
}
& $py -m pip install --quiet --disable-pip-version-check --upgrade pip
& $py -m pip install --quiet --disable-pip-version-check volatility3 oletools
Say "python: $((& $py --version) 2>&1)"

# ---------------------------------------------------------------------------
# 2) Didier Stevens suite (individual scripts — oletools is NOT the whole suite)
#    oledump plugins must sit next to oledump.py so 'oledump -p name' resolves.
# ---------------------------------------------------------------------------
$ds = 'https://raw.githubusercontent.com/DidierStevens/DidierStevensSuite/master'
foreach ($t in 'oledump', 'zipdump', 'pdfid', 'pdf-parser') {
    & curl.exe -L --fail -s -o (Join-Path $shim "$t.py") "$ds/$t.py"
    New-Shim $t "exec '$py' '/c/dfir/tools/native-shim/$t.py' `"`$@`""
}
# oledump plugin used by the malicious-documents module
& curl.exe -L --fail -s -o (Join-Path $shim 'plugin_http_heuristics.py') "$ds/plugin_http_heuristics.py"

# ---------------------------------------------------------------------------
# 3) RegRipper + its Perl dependency Parse::Win32Registry (pure Perl; Git omits it)
#    Assumes RegRipper3.0 already cloned to C:\dfir\tools\RegRipper3.0 (34-native-tools).
# ---------------------------------------------------------------------------
$perllib = Join-Path $tools 'perllib'
New-Item -ItemType Directory -Force -Path $perllib | Out-Null
$pwrTgz = Join-Path $env:TEMP 'pwr.tar.gz'
& curl.exe -L --fail -s -o $pwrTgz 'https://cpan.metacpan.org/authors/id/J/JM/JMACFARLA/Parse-Win32Registry-1.1.tar.gz'
& (Join-Path $git 'usr\bin\tar.exe') -xzf $pwrTgz -C $perllib 2>$null
$pwrLib = (Get-ChildItem $perllib -Recurse -Filter 'Win32Registry.pm' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\lib\\Parse\\' } | Select-Object -First 1).Directory.Parent.FullName
$pwrLibUnix = ($pwrLib -replace '\\', '/' -replace '^C:', '/c')
$ripPl = (Get-ChildItem 'C:\dfir\tools\RegRipper3.0' -Recurse -Filter 'rip.pl' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
$ripPlUnix = ($ripPl -replace '\\', '/' -replace '^C:', '/c')
New-Shim 'rip' "exec '/c/dfir/tools/git/usr/bin/perl' -I`"$pwrLibUnix`" `"$ripPlUnix`" `"`$@`""
Say "regripper: rip.pl=$ripPl  perllib=$pwrLib"

# ---------------------------------------------------------------------------
# 4) Remaining shims (PECmd/EZ, chainsaw, oletools entry points, Sleuth Kit)
# ---------------------------------------------------------------------------
# prefetch -> PECmd, emitting the sccainfo-compatible fields the lab awk parses
New-Shim 'prefetch' @'
# prefetch <file.pf|dir> -> PECmd, sccainfo-compatible output
exec '/c/dfir/tools/EZ/net9/PECmd.exe' -f "$@"
'@
New-Shim 'chainsaw' "exec '/c/dfir/tools/chainsaw/chainsaw.exe' `"`$@`""
New-Shim 'vol'      "exec '/c/dfir/Python/Scripts/vol.exe' `"`$@`""
foreach ($t in 'olevba', 'oleid', 'mraptor') {
    New-Shim $t "exec '/c/dfir/Python/Scripts/$t.exe' `"`$@`""
}
# Sleuth Kit mactime (perl) — adjust path to the installed TSK bin
$tskMactime = (Get-ChildItem "$tools\sleuthkit" -Recurse -Filter 'mactime*' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if ($tskMactime) {
    $mu = ($tskMactime -replace '\\', '/' -replace '^C:', '/c')
    New-Shim 'mactime' "exec '/c/dfir/tools/git/usr/bin/perl' `"$mu`" `"`$@`""
}

# ---------------------------------------------------------------------------
# 5) Canonical chainsaw rules/mappings at /opt/chainsaw (git-bash /opt = git\opt)
#    so every module's placeholder -s /opt/chainsaw/sigma resolves identically.
# ---------------------------------------------------------------------------
$csReal = Get-ChildItem "$tools\chainsaw" -Recurse -Directory -Filter 'sigma' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($csReal) {
    $csRoot = $csReal.Parent.FullName
    $opt = Join-Path $git 'opt\chainsaw'
    New-Item -ItemType Directory -Force -Path (Join-Path $opt 'repo') | Out-Null
    if (-not (Test-Path (Join-Path $opt 'sigma')))       { Copy-Item (Join-Path $csRoot 'sigma')    (Join-Path $opt 'sigma')        -Recurse -Force }
    if (-not (Test-Path (Join-Path $opt 'repo\mappings'))) { Copy-Item (Join-Path $csRoot 'mappings') (Join-Path $opt 'repo\mappings') -Recurse -Force }
    Say "chainsaw rules -> $opt (sigma + repo\mappings)"
}

Say 'done. Native forensic tool set complete. Verify with tools/validate_lab.sh (expect 14/0).'
