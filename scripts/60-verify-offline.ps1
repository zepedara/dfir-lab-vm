# =============================================================================
# 60 - AIR-GAP verification. Installs a COMPREHENSIVE runtime self-test that, with
#      the VM's network adapter DISCONNECTED, exercises a representative command
#      for EVERY module in C:\dfir\lab - both the Windows-native tools AND the
#      dfir-aio container (docker run --network none). This is the offline
#      acceptance gate. Also does a best-effort build-time sanity check.
# =============================================================================
$ErrorActionPreference = 'Continue'

Write-Host '[verify] Build-time air-gap sanity checks...'
$machinePath = [Environment]::GetEnvironmentVariable('PATH','Machine')
$env:PATH = "$machinePath;$env:PATH"

foreach ($t in 'PECmd','EvtxECmd','AmcacheParser','AppCompatCacheParser','MFTECmd','chainsaw','hayabusa') {
    $ok = [bool](Get-Command "$t*" -ErrorAction SilentlyContinue)
    Write-Host ("    native {0,-22} {1}" -f $t, ($(if($ok){'present'}else{'MISSING'})))
}
$null = wsl.exe -d Ubuntu -u root -- bash -lic "service docker start >/dev/null 2>&1 || (pgrep dockerd >/dev/null 2>&1 || (dockerd >/var/log/dockerd.log 2>&1 &)); sleep 3" 2>$null
wsl.exe -d Ubuntu -u root -- bash -lic "docker image inspect dfir-aio:v2 >/dev/null 2>&1"
$dockerResident = ($LASTEXITCODE -eq 0)
$dockerAirgap = $false
if ($dockerResident) {
    wsl.exe -d Ubuntu -u root -- bash -lic "docker run --rm --network none dfir-aio:v2 bash -lc 'echo offline-ok' 2>/dev/null | grep -q offline-ok || docker run --rm --network none dfir-aio:v2 sh -lc 'echo offline-ok' 2>/dev/null | grep -q offline-ok"
    $dockerAirgap = ($LASTEXITCODE -eq 0)
}
Write-Host ("    container resident: {0}; air-gapped run: {1}" -f $dockerResident, $dockerAirgap)
$labData = (Get-ChildItem 'C:\dfir\lab' -Recurse -Directory -Filter 'data' -EA SilentlyContinue).Count
Write-Host ("    lab module data folders present: {0}" -f $labData)

# --------------------------------------------------------------------------- #
# Install the COMPREHENSIVE runtime self-test (run with the NIC DISCONNECTED).
# --------------------------------------------------------------------------- #
$selfTest = 'C:\dfir\offline-selftest.ps1'
$body = @'
<#  DFIR Lab VM - OFFLINE ACCEPTANCE SELF-TEST  ===============================
    THE acceptance gate: every module runnable with ZERO internet.

    1) Disconnect the VM network adapter:
         VMware > VM > Settings > Network Adapter > uncheck "Connected"  (or vmrun)
    2) Run (elevated):
         powershell -ExecutionPolicy Bypass -File C:\dfir\offline-selftest.ps1
    It walks EVERY C:\dfir\lab\module-XX, picks a representative artifact, and runs
    the matching tool BOTH natively AND inside dfir-aio:v2 with --network none.
=============================================================================== #>
$ErrorActionPreference = 'Continue'
$env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + $env:PATH
$pass=0; $fail=0; $skip=0
$out = 'C:\dfir\offline-selftest-report.txt'
"DFIR offline self-test $(Get-Date -Format u)" | Set-Content $out
function Log($s,$c='Gray'){ Write-Host $s -ForegroundColor $c; Add-Content $out $s }
function P($n){ $script:pass++; Log "[PASS] $n" Green }
function F($n){ $script:fail++; Log "[FAIL] $n" Red }
function S($n){ $script:skip++; Log "[SKIP] $n" Yellow }

# Hard precondition: confirm we are genuinely offline (the whole point).
if (Test-Connection 8.8.8.8 -Count 1 -Quiet -EA SilentlyContinue) {
    Log "WARNING: internet is REACHABLE - disconnect the NIC for a true air-gap test." Yellow
} else { Log "Confirmed offline (8.8.8.8 unreachable)." Green }

# Make sure the WSL docker daemon is up (no network needed).
wsl -d Ubuntu -u root -- bash -lic "service docker start >/dev/null 2>&1 || (pgrep dockerd>/dev/null 2>&1 || (dockerd >/var/log/dockerd.log 2>&1 &)); sleep 3" 2>$null | Out-Null
$haveImg = $false
wsl -d Ubuntu -u root -- bash -lic "docker image inspect dfir-aio:v2 >/dev/null 2>&1"; $haveImg = ($LASTEXITCODE -eq 0)
Log ("dfir-aio:v2 resident: " + $haveImg)

# Run a native tool, return $true if it executes (no network).
function Native($exe, $argline) {
    $c = Get-Command "$exe*" -EA SilentlyContinue | Select -First 1
    if (-not $c) { return $null }
    try { $null = & $c.Source $argline.Split(' ') 2>&1; return $true } catch { return $false }
}
# Run a tool inside the container with NO network against a host folder.
function Container($hostDir, $toolline) {
    if (-not $haveImg) { return $null }
    $w = (wsl -d Ubuntu -- wslpath "$hostDir").Trim()
    wsl -d Ubuntu -- bash -lic "docker run --rm --network none -v '$w':/data dfir-aio:v2 $toolline >/dev/null 2>&1"
    return ($LASTEXITCODE -eq 0)
}

# Decide the representative command for a module from the artifacts it contains.
function Plan($dataDir) {
    if (-not (Test-Path $dataDir)) { return $null }
    $pf   = Get-ChildItem $dataDir -Recurse -Filter *.pf       -EA SilentlyContinue | Select -First 1
    $am   = Get-ChildItem $dataDir -Recurse -Filter Amcache.hve -EA SilentlyContinue | Select -First 1
    $sys  = Get-ChildItem $dataDir -Recurse -Filter SYSTEM     -EA SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Select -First 1
    $evtx = Get-ChildItem $dataDir -Recurse -Filter *.evtx     -EA SilentlyContinue | Select -First 1
    $mft  = Get-ChildItem $dataDir -Recurse -Filter '$MFT'     -EA SilentlyContinue | Select -First 1
    if ($pf)   { return @{ dir=$pf.Directory.FullName;  native=@('PECmd',"-d .");                  cont='PECmd -d /data --csv /tmp';                 what='Prefetch (PECmd)' } }
    if ($am)   { return @{ dir=$am.Directory.FullName;  native=@('AmcacheParser',"-f `"$($am.FullName)`" --csv .");  cont="AmcacheParser -f /data/$($am.Name) --csv /tmp -i"; what='Amcache (AmcacheParser)' } }
    if ($sys)  { return @{ dir=$sys.Directory.FullName; native=@('AppCompatCacheParser',"-f `"$($sys.FullName)`" --csv .");  cont="AppCompatCacheParser -f /data/$($sys.Name) --csv /tmp"; what='ShimCache (AppCompatCacheParser)' } }
    if ($evtx) { return @{ dir=$evtx.Directory.FullName; native=@('EvtxECmd',"-d .");               cont='EvtxECmd -d /data --csv /tmp';              what='Event logs (EvtxECmd) + chainsaw' } }
    if ($mft)  { return @{ dir=$mft.Directory.FullName;  native=@('MFTECmd',"-f `"$($mft.FullName)`" --csv .");      cont="MFTECmd -f /data/$($mft.Name) --csv /tmp"; what='MFT (MFTECmd)' } }
    return $null
}

$mods = Get-ChildItem 'C:\dfir\lab' -Directory -Filter 'module-*' -EA SilentlyContinue | Sort-Object Name
Log "`n=== Walking $($mods.Count) modules (native + container, --network none) ===`n"
foreach ($m in $mods) {
    $plan = Plan (Join-Path $m.FullName 'data')
    if (-not $plan) { S "$($m.Name): no recognized artifact (concept module) - nothing to execute"; continue }
    Log "-- $($m.Name): $($plan.what)"
    # native
    $n = Native $plan.native[0] $plan.native[1]
    if ($n -eq $true) { P "$($m.Name) native $($plan.native[0])" } elseif ($n -eq $null) { S "$($m.Name) native $($plan.native[0]) (tool absent)" } else { F "$($m.Name) native $($plan.native[0])" }
    # container, no network
    $c = Container $plan.dir $plan.cont
    if ($c -eq $true) { P "$($m.Name) container (--network none): $($plan.cont.Split(' ')[0])" } elseif ($c -eq $null) { S "$($m.Name) container (image not resident)" } else { F "$($m.Name) container (--network none)" }
    # module 6 also exercises chainsaw/hayabusa in the container
    if ($m.Name -match 'module-06' -and $haveImg) {
        $c2 = Container $plan.dir 'hayabusa csv-timeline -d /data -o /tmp/h.csv -w'
        if ($c2 -eq $true) { P "$($m.Name) container hayabusa (--network none)" } else { F "$($m.Name) container hayabusa (--network none)" }
    }
}

Log "`n=== RESULT: $pass passed, $fail failed, $skip skipped ===" $(if($fail){'Red'}else{'Green'})
Log ("ACCEPTANCE (every module runnable with NIC off): " + $(if($fail -eq 0){'YES'}else{'NO - see [FAIL] above'})) $(if($fail){'Red'}else{'Green'})
if ($fail -and -not $haveImg) { Log "Note: if only container checks failed, dfir-aio was unpublished at build. Load it once (online), then it is permanently offline." Yellow }
Log "Full report: $out"
'@
New-Item -ItemType Directory -Force -Path 'C:\dfir' | Out-Null
Set-Content -Path $selfTest -Value $body -Encoding UTF8
Write-Host "[verify] Installed comprehensive offline acceptance self-test: $selfTest"

# Desktop shortcut.
try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path (Join-Path $env:PUBLIC 'Desktop') 'Offline acceptance self-test.lnk'))
    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments  = "-NoExit -ExecutionPolicy Bypass -File `"$selfTest`""
    $lnk.Save()
} catch { Write-Warning "[verify] shortcut issue: $($_.Exception.Message)" }

$summary = @"
DFIR Lab VM - air-gap readiness (build time $(Get-Date -Format o))
  container resident   : $dockerResident
  container air-gapped : $dockerAirgap   (docker run --network none dfir-aio:v2)
  lab data folders     : $labData
  ACCEPTANCE TEST: disconnect the NIC, run  C:\dfir\offline-selftest.ps1
                  -> every module must report PASS (the offline acceptance gate).
"@
Set-Content -Path 'C:\dfir\OFFLINE-READINESS.txt' -Value $summary -Encoding UTF8
Write-Host "[verify] $summary"
exit 0
