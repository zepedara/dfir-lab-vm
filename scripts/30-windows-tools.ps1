# =============================================================================
# 30 - Install the Windows-native DFIR tools the lab uses:
#       * Eric Zimmerman's tools (.NET 9 builds)
#       * Chainsaw (Windows build + bundled Sigma rules/mappings)
#       * Hayabusa (Windows x64 build + rules)
#       * Sysinternals (Sysmon etc., handy for module 10)
# All land under C:\dfir\tools and get put on the machine PATH.
#
# OFFLINE-FIRST: EZ tools / Chainsaw / Hayabusa are pulled from the VENDORED
# GitHub release  zepedara/dfir-lab-vm @ deps-v1  (so a locked-down / DoD network
# never has to reach hashicorp / ericzimmerman / WithSecureLabs / Yamato-Security).
# Each tool falls back to its original upstream URL ONLY if the vendored fetch
# fails. The bits are baked into the image at build time so the built VM is fully
# offline. PowerShell 5.1-safe (no ?? / ternary / ?.); throw not exit on hard fail.
# =============================================================================
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Vendored dependency release (tokenless public assets).
$DepsBase  = 'https://github.com/zepedara/dfir-lab-vm/releases/download/deps-v1'

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
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}
# Download a single VENDORED asset from the deps-v1 release into $dest and extract.
# Returns $true on success, $false on failure (so caller can fall back upstream).
function Get-Vendored($assetName, $dest) {
    try {
        $u   = "$DepsBase/$assetName"
        $zip = Join-Path $env:TEMP $assetName
        Invoke-WebRequest $u -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dest -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Write-Warning "[vendor] fetch of $assetName from deps-v1 failed: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------- .NET 9 runtime -----------------------------
# The EZ tools are FRAMEWORK-DEPENDENT .NET 9 builds (NOT self-contained) -
# PECmd/EvtxECmd/AppCompatCacheParser etc. will fail at launch ("You must install
# or update .NET... Microsoft.NETCore.App 9.0.0") unless the .NET 9 runtime is
# present. A fresh Windows VM has none, so we bake the .NET 9 Desktop Runtime
# (superset: includes NETCore.App + the WindowsDesktop libs the EZ GUI tools need)
# into C:\dfir\tools\dotnet now. (Microsoft host - kept as-is per the build fix.)
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
# Vendored EZTools.zip extracts a net9\ tree (PECmd, EvtxECmd, AppCompatCacheParser,
# AmcacheParser, MFTECmd, RECmd, SBECmd, RBCmd, LECmd, JLECmd, SrumECmd, SQLECmd)
# with EvtxeCmd\Maps, RECmd\BatchExamples and SQLECmd\Maps already baked in.
Write-Host '[ez] Installing Eric Zimmerman tools (vendored EZTools.zip -> deps-v1)...'
$gotEz = Get-Vendored 'EZTools.zip' $EZ
if ($gotEz) {
    Write-Host "[ez] EZ tools installed from vendored deps-v1 release under $EZ"
} else {
    Write-Warning '[ez] Falling back to upstream Get-ZimmermanTools.ps1...'
    try {
        $gzt = Join-Path $env:TEMP 'Get-ZimmermanTools.ps1'
        Invoke-WebRequest 'https://raw.githubusercontent.com/EricZimmerman/Get-ZimmermanTools/master/Get-ZimmermanTools.ps1' -OutFile $gzt -UseBasicParsing
        & powershell -NoProfile -ExecutionPolicy Bypass -File $gzt -Dest $EZ -NetVersion 9
        $gotEz = $true
        Write-Host "[ez] EZ tools installed (upstream fallback) under $EZ"
    } catch {
        Write-Warning "[ez] Get-ZimmermanTools fallback failed: $($_.Exception.Message). EZ tools can be installed later from the desktop README."
    }
}
if ($gotEz) {
    # AIR-GAP: bake the maps/definitions locally so tools never fetch at runtime.
    # EvtxECmd needs Maps\, RECmd needs BatchExamples\, SQLECmd needs Maps\. The
    # vendored zip already contains them; --sync just refreshes if online (noop
    # offline). Wrapped so a blocked network never fails the build.
    foreach ($t in @('EvtxECmd','RECmd','SQLECmd')) {
        $tExe = Get-ChildItem $EZ -Recurse -Filter "$t.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($tExe) {
            Write-Host "[ez] Syncing $t maps/definitions (offline bake)..."
            try { & $tExe.FullName --sync 2>$null } catch { Write-Warning "[ez] $t --sync failed: $($_.Exception.Message)" }
        }
    }
}

# --------------------------------- Chainsaw ---------------------------------
# Vendored chainsaw_all_platforms+rules.zip extracts chainsaw\ with the Windows
# x64 exe (chainsaw_x86_64-pc-windows-msvc.exe) PLUS sigma\, mappings\, rules\.
# We KEEP the whole tree so offline `chainsaw hunt ... -s <sigma> --mapping <map>` works.
Write-Host '[chainsaw] Installing Chainsaw (vendored: Windows build + bundled Sigma rules)...'
try {
    $gotCs = Get-Vendored 'chainsaw_all_platforms+rules.zip' $ChainsawD
    if (-not $gotCs) {
        Write-Warning '[chainsaw] Falling back to upstream WithSecureLabs/chainsaw latest...'
        try   { $url = Get-LatestRelease 'WithSecureLabs/chainsaw' 'chainsaw_all_platforms\+rules\.zip$' }
        catch { $url = Get-LatestRelease 'WithSecureLabs/chainsaw' 'chainsaw_all_platforms.*\.zip$' }
        Expand-To $url $ChainsawD
    }
    $exe = Get-ChildItem $ChainsawD -Recurse -Filter '*windows*.exe' | Select-Object -First 1
    if ($exe) { Copy-Item $exe.FullName (Join-Path $ChainsawD 'chainsaw.exe') -Force }
    $sigma = Get-ChildItem $ChainsawD -Recurse -Directory -Filter 'sigma' -ErrorAction SilentlyContinue | Select-Object -First 1
    $maps  = Get-ChildItem $ChainsawD -Recurse -Directory -Filter 'mappings' -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "[chainsaw] Installed. Sigma rules baked: $([bool]$sigma); mappings baked: $([bool]$maps)"
} catch {
    Write-Warning "[chainsaw] install failed: $($_.Exception.Message)"
}

# --------------------------------- Hayabusa ---------------------------------
# Vendored hayabusa-3.9.0-win-x64.zip is the x64 Windows build WITH rules\ baked
# in. (A prior bug grabbed the arm64 live-response asset -> "not a valid
# application for this OS platform"; the vendored zip is pinned x64.)
Write-Host '[hayabusa] Installing Hayabusa (vendored: Windows x64 build + rules)...'
try {
    $gotHb = Get-Vendored 'hayabusa-3.9.0-win-x64.zip' $HayabusaD
    if (-not $gotHb) {
        Write-Warning '[hayabusa] Falling back to upstream Yamato-Security/hayabusa latest (win-x64)...'
        $url = Get-LatestRelease 'Yamato-Security/hayabusa' 'hayabusa-.*-win-x64\.zip$'
        Expand-To $url $HayabusaD
    }
    # Pick the x64 exe explicitly in case multiple arch exes are present.
    $exe = Get-ChildItem $HayabusaD -Recurse -Filter 'hayabusa*.exe' |
           Where-Object { $_.Name -match 'x64' } | Select-Object -First 1
    if (-not $exe) { $exe = Get-ChildItem $HayabusaD -Recurse -Filter 'hayabusa*.exe' | Select-Object -First 1 }
    if ($exe) { Copy-Item $exe.FullName (Join-Path $HayabusaD 'hayabusa.exe') -Force }
    # Rules are already baked in the vendored zip. update-rules just refreshes if
    # online; noop/!fail offline. Wrapped so a blocked network never fails build.
    try { Push-Location $HayabusaD; & (Join-Path $HayabusaD 'hayabusa.exe') update-rules 2>$null; Pop-Location } catch {}
    $hrules = Get-ChildItem $HayabusaD -Recurse -Directory -Filter 'rules' -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "[hayabusa] Installed. Rules baked: $([bool]$hrules)"
} catch {
    Write-Warning "[hayabusa] install failed: $($_.Exception.Message)"
}

# ------------------------------- Sysinternals -------------------------------
# Microsoft host (download.sysinternals.com). Not vendored - it is a Microsoft
# property, like the .NET runtime and the Windows ISO. Non-fatal if blocked.
Write-Host '[sysinternals] Installing Sysinternals (Sysmon, Autoruns, etc.)...'
try {
    Expand-To 'https://download.sysinternals.com/files/SysinternalsSuite.zip' $Sysint
    Write-Host '[sysinternals] Installed.'
} catch {
    Write-Warning "[sysinternals] install failed: $($_.Exception.Message)"
}

# ------------------------- Put everything on PATH ---------------------------
# EZ layout has flat tools (PECmd.exe at net9\) AND subfolder tools (EvtxeCmd\,
# RECmd\, SQLECmd\). Add EVERY directory that directly holds an EZ .exe so all
# tools resolve on PATH, then the other tool roots.
Write-Host '[path] Adding tools to the machine PATH...'
$ezExeDirs = @(Get-ChildItem $EZ -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.DirectoryName } | Sort-Object -Unique)
if (-not $ezExeDirs -or $ezExeDirs.Count -eq 0) { $ezExeDirs = @($EZ) }
$paths = @()
$paths += $ezExeDirs
$paths += @($ChainsawD, $HayabusaD, $Sysint, $DotNet)
$cur = [Environment]::GetEnvironmentVariable('PATH','Machine')
foreach ($p in $paths) {
    if ($p -and ($cur -notlike "*$p*")) { $cur = "$cur;$p" }
}
[Environment]::SetEnvironmentVariable('PATH', $cur, 'Machine')
Write-Host '[path] Done. New shells will see PECmd, EvtxECmd, chainsaw, hayabusa, sysmon, etc.'
exit 0
