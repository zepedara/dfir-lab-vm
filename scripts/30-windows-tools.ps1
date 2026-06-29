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
$DotNet    = Join-Path $Root 'dotnet'
New-Item -ItemType Directory -Force -Path $Root,$EZ,$ChainsawD,$HayabusaD,$Sysint,$DotNet | Out-Null

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

# ------------------------------- .NET 9 runtime -----------------------------
# The EZ tools fetched below with -NetVersion 9 are FRAMEWORK-DEPENDENT .NET 9
# builds (NOT self-contained) - PECmd/EvtxECmd/AppCompatCacheParser etc. will
# fail at launch ("You must install or update .NET... Microsoft.NETCore.App
# 9.0.0") unless the .NET 9 runtime is present. A fresh Windows VM has none, so
# we bake the .NET 9 Desktop Runtime (superset: includes NETCore.App + the
# WindowsDesktop libs the EZ GUI tools need) into C:\dfir\tools\dotnet now.
Write-Host '[dotnet] Installing the .NET 9 Desktop Runtime (required by the EZ tools)...'
try {
    $dgi = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dgi -UseBasicParsing
    & powershell -NoProfile -ExecutionPolicy Bypass -File $dgi -Runtime windowsdesktop -Channel 9.0 -InstallDir $DotNet -NoPath
    # Make the private runtime discoverable by the EZ apphost .exes (machine-wide).
    [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $DotNet, 'Machine')
    $env:DOTNET_ROOT = $DotNet
    Write-Host "[dotnet] .NET 9 runtime installed under $DotNet"
} catch {
    Write-Warning "[dotnet] .NET 9 runtime install failed: $($_.Exception.Message). EZ tools will not run until a .NET 9 runtime is installed."
}

# ----------------------------- Eric Zimmerman -------------------------------
Write-Host '[ez] Installing Eric Zimmerman tools via Get-ZimmermanTools.ps1...'
try {
    $gzt = Join-Path $env:TEMP 'Get-ZimmermanTools.ps1'
    Invoke-WebRequest 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -OutFile $gzt -UseBasicParsing
    # -NetVersion 9 pulls the framework-dependent .NET 9 builds (need the runtime
    # installed above). They are smaller than self-contained builds but require it.
    & powershell -NoProfile -ExecutionPolicy Bypass -File $gzt -Dest $EZ -NetVersion 9
    Write-Host "[ez] EZ tools installed under $EZ"

    # AIR-GAP: bake the maps/definitions locally so tools never fetch at runtime.
    # EvtxECmd needs Maps\, RECmd needs BatchExamples\, SQLECmd needs Maps\. Their
    # --sync downloads those packs now (build time) so the VM is offline-ready.
    foreach ($t in @('EvtxECmd','RECmd','SQLECmd')) {
        $tExe = Get-ChildItem $EZ -Recurse -Filter "$t.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tExe) {
            Write-Host "[ez] Syncing $t maps/definitions (offline bake)..."
            try { & $tExe.FullName --sync 2>$null } catch { Write-Warning "[ez] $t --sync failed: $($_.Exception.Message)" }
        }
    }
} catch {
    Write-Warning "[ez] Get-ZimmermanTools failed: $($_.Exception.Message). EZ tools can be installed later from the desktop README."
}

# --------------------------------- Chainsaw ---------------------------------
# AIR-GAP: grab the "+rules" asset so the Sigma rules + event mappings are baked
# in. We KEEP the whole extracted tree (sigma\, mappings\, rules\) - never delete
# it - so offline `chainsaw hunt ... -s <sigma> --mapping <mappings>` works.
Write-Host '[chainsaw] Installing Chainsaw (Windows build + bundled Sigma rules)...'
try {
    try   { $url = Get-LatestRelease 'WithSecureLabs/chainsaw' 'chainsaw_all_platforms\+rules\.zip$' }
    catch { $url = Get-LatestRelease 'WithSecureLabs/chainsaw' 'chainsaw_all_platforms.*\.zip$' }
    Expand-To $url $ChainsawD
    $exe = Get-ChildItem $ChainsawD -Recurse -Filter '*windows*.exe' | Select-Object -First 1
    if ($exe) { Copy-Item $exe.FullName (Join-Path $ChainsawD 'chainsaw.exe') -Force }
    $sigma = Get-ChildItem $ChainsawD -Recurse -Directory -Filter 'sigma' -ErrorAction SilentlyContinue | Select-Object -First 1
    $maps  = Get-ChildItem $ChainsawD -Recurse -Directory -Filter 'mappings' -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "[chainsaw] Installed. Sigma rules baked: $([bool]$sigma); mappings baked: $([bool]$maps)"
} catch {
    Write-Warning "[chainsaw] install failed: $($_.Exception.Message)"
}

# --------------------------------- Hayabusa ---------------------------------
Write-Host '[hayabusa] Installing Hayabusa (Windows build)...'
try {
    # Hayabusa ships several Windows zips (win-x64, win-arm64/aarch64, win-x86,
    # plus *-live-response variants). The loose pattern 'hayabusa.*win.*\.zip$'
    # matched the *arm64 live-response* asset first -> an ARM64 binary that won't
    # run on the x64 VM ("not a valid application for this OS platform"). Pin x64.
    $url = Get-LatestRelease 'Yamato-Security/hayabusa' 'hayabusa-.*-win-x64\.zip$'
    Expand-To $url $HayabusaD
    # Pick the x64 exe explicitly in case multiple arch exes are present.
    $exe = Get-ChildItem $HayabusaD -Recurse -Filter 'hayabusa*.exe' |
           Where-Object { $_.Name -match 'x64' } | Select-Object -First 1
    if (-not $exe) { $exe = Get-ChildItem $HayabusaD -Recurse -Filter 'hayabusa*.exe' | Select-Object -First 1 }
    if ($exe) { Copy-Item $exe.FullName (Join-Path $HayabusaD 'hayabusa.exe') -Force }
    # AIR-GAP: download the rules NOW (build time) into rules\ so timeline/detect
    # works offline. update-rules clones the hayabusa-rules repo locally.
    try { Push-Location $HayabusaD; & (Join-Path $HayabusaD 'hayabusa.exe') update-rules 2>$null; Pop-Location } catch {}
    $hrules = Get-ChildItem $HayabusaD -Recurse -Directory -Filter 'rules' -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "[hayabusa] Installed. Rules baked: $([bool]$hrules)"
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
$paths = @($ezPath, $ChainsawD, $HayabusaD, $Sysint, $DotNet)
$cur = [Environment]::GetEnvironmentVariable('PATH','Machine')
foreach ($p in $paths) {
    if ($cur -notlike "*$p*") { $cur = "$cur;$p" }
}
[Environment]::SetEnvironmentVariable('PATH', $cur, 'Machine')
Write-Host '[path] Done. New shells will see PECmd, EvtxECmd, chainsaw, hayabusa, sysmon, etc.'
exit 0
