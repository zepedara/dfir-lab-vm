# =============================================================================
# 30 - Install the Windows-native DFIR tools the lab uses:
#       * Eric Zimmerman's tools (via Get-ZimmermanTools.ps1)
#       * Chainsaw (Windows build)
#       * Hayabusa (Windows build)
#       * Sysinternals (Sysmon etc., handy for module 10)
# All land under C:\dfir\tools and get put on the machine PATH.
# =============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = 'C:\dfir\tools'
$EZ        = Join-Path $Root 'EZ'
$ChainsawD = Join-Path $Root 'chainsaw'
$HayabusaD = Join-Path $Root 'hayabusa'
$Sysint    = Join-Path $Root 'sysinternals'
New-Item -ItemType Directory -Force -Path $Root,$EZ,$ChainsawD,$HayabusaD,$Sysint | Out-Null

function Get-LatestRelease($ownerRepo, $assetPattern) {
    # Return the browser_download_url of the first asset matching the regex.
    $api = "https://api.github.com/repos/$ownerRepo/releases/latest"
    $rel = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'dfir-lab-vm' }
    $a = $rel.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
    if (-not $a) { throw "No asset matching '$assetPattern' in $ownerRepo latest release" }
    return $a.browser_download_url
}
function Expand-To($url, $dest) {
    $zip = Join-Path $env:TEMP ([IO.Path]::GetFileName($url))
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    Expand-Archive $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force
}

# ----------------------------- Eric Zimmerman -------------------------------
Write-Host '[ez] Installing Eric Zimmerman tools via Get-ZimmermanTools.ps1...'
try {
    $gzt = Join-Path $env:TEMP 'Get-ZimmermanTools.ps1'
    Invoke-WebRequest 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -OutFile $gzt -UseBasicParsing
    # -NetVersion 9 pulls the .NET 9 self-contained builds (no separate runtime needed).
    & powershell -NoProfile -ExecutionPolicy Bypass -File $gzt -Dest $EZ -NetVersion 9
    Write-Host "[ez] EZ tools installed under $EZ"
} catch {
    Write-Warning "[ez] Get-ZimmermanTools failed: $($_.Exception.Message). EZ tools can be installed later from the desktop README."
}

# --------------------------------- Chainsaw ---------------------------------
Write-Host '[chainsaw] Installing Chainsaw (Windows build)...'
try {
    $url = Get-LatestRelease 'WithSecureLabs/chainsaw' 'chainsaw_all_platforms.*\.zip$'
    Expand-To $url $ChainsawD
    # The archive nests a chainsaw\ folder containing chainsaw_x86_64-pc-windows-msvc.exe
    $exe = Get-ChildItem $ChainsawD -Recurse -Filter '*windows*.exe' | Select-Object -First 1
    if ($exe) { Copy-Item $exe.FullName (Join-Path $ChainsawD 'chainsaw.exe') -Force }
    # Bring along the bundled sigma + mappings if present (for offline hunting).
    Write-Host '[chainsaw] Installed.'
} catch {
    Write-Warning "[chainsaw] install failed: $($_.Exception.Message)"
}

# --------------------------------- Hayabusa ---------------------------------
Write-Host '[hayabusa] Installing Hayabusa (Windows build)...'
try {
    $url = Get-LatestRelease 'Yamato-Security/hayabusa' 'hayabusa.*win.*\.zip$'
    Expand-To $url $HayabusaD
    $exe = Get-ChildItem $HayabusaD -Recurse -Filter 'hayabusa*.exe' | Select-Object -First 1
    if ($exe) { Copy-Item $exe.FullName (Join-Path $HayabusaD 'hayabusa.exe') -Force }
    # Build the rules/encoded-rules so it works offline.
    try { Push-Location $HayabusaD; & (Join-Path $HayabusaD 'hayabusa.exe') update-rules 2>$null; Pop-Location } catch {}
    Write-Host '[hayabusa] Installed.'
} catch {
    Write-Warning "[hayabusa] install failed: $($_.Exception.Message)"
}

# ------------------------------- Sysinternals -------------------------------
Write-Host '[sysinternals] Installing Sysinternals (Sysmon, Autoruns, etc.)...'
try {
    Expand-To 'https://download.sysinternals.com/files/SysinternalsSuite.zip' $Sysint
    Write-Host '[sysinternals] Installed.'
} catch {
    Write-Warning "[sysinternals] install failed: $($_.Exception.Message)"
}

# ------------------------- Put everything on PATH ---------------------------
Write-Host '[path] Adding tools to the machine PATH...'
$ezBin = (Get-ChildItem $EZ -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'net9|net6' } | Select-Object -First 1)
$ezPath = if ($ezBin) { $ezBin.FullName } else { $EZ }
$paths = @($ezPath, $ChainsawD, $HayabusaD, $Sysint)
$cur = [Environment]::GetEnvironmentVariable('PATH','Machine')
foreach ($p in $paths) {
    if ($cur -notlike "*$p*") { $cur = "$cur;$p" }
}
[Environment]::SetEnvironmentVariable('PATH', $cur, 'Machine')
Write-Host '[path] Done. New shells will see PECmd, EvtxECmd, chainsaw, hayabusa, sysmon, etc.'
exit 0
