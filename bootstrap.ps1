<#
.SYNOPSIS
  DFIR Lab VM - one-liner bootstrap.

  Builds a Windows 10 + WSL2 VMware Workstation Pro VM, preloaded with the entire
  zepedara DFIR lab: the dfir-aio container (in WSL), Eric Zimmerman's tools,
  Chainsaw + Hayabusa (Windows builds), and the dfir-training-lab walkthrough.
  Boot it and follow the lab natively - both Windows-native tools AND the Linux
  dfir-aio container.

.DESCRIPTION
  Headline one-liner (run in an *elevated* PowerShell on your Windows host):

      iwr https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/bootstrap.ps1 | iex

  What I do, in order:
    1. Check prerequisites - VMware Workstation Pro, ~30 GB free disk,
       hardware virtualization enabled, internet reachable.
    2. Install HashiCorp Packer if it is missing (winget -> choco -> direct zip).
    3. Download this kit (git clone, or zip fallback).
    4. Auto-resolve a FRESH, valid Windows ISO download link from Microsoft
       (via the vendored Fido helper) - no variables to set. Turnkey.
    5. Kick off the Packer build of the VM.
    6. Print clear next steps - where the .vmx lands and how to open it.

  LEGAL: This kit never redistributes Windows. We do NOT host the ISO. At build
  time we resolve a fresh, time-limited Windows 10 download link from Microsoft's
  own servers (using the vendored Fido helper, which queries Microsoft's official
  download API) and the ISO downloads straight FROM MICROSOFT. You accept
  Microsoft's licence at build time. Lab use only (Pro edition, 30-day rearm).

  Tunable via environment variables BEFORE you run the one-liner, e.g.:
      $env:DFIR_VM_BRANCH = 'main'      # kit branch to pull
      $env:DFIR_VM_DIR    = 'C:\dfir-lab-vm'   # where to clone the kit
      $env:DFIR_SKIP_BUILD = '1'        # set up everything but do NOT run packer
      $env:DFIR_ISO_URL    = '<iso url>'   # OPTIONAL: skip auto-fetch, use this ISO
                                           #   (e.g. file:///C:/iso/Win10.iso from a
                                           #    media share on a locked-down network)
      $env:DFIR_ISO_SHA256 = '<sha256>'    # OPTIONAL: checksum for DFIR_ISO_URL
#>
$ErrorActionPreference = 'Continue'  # native tools (git/packer) write progress to stderr; Stop would treat that as fatal
Set-StrictMode -Version 1

# ---------------------------------------------------------------------------
# Config (env-overridable)
# ---------------------------------------------------------------------------
$RepoOwner = 'zepedara'
$RepoName  = 'dfir-lab-vm'
$DepsBase  = "https://github.com/$RepoOwner/$RepoName/releases/download/deps-v1"  # vendored deps
$Branch    = if ($env:DFIR_VM_BRANCH) { $env:DFIR_VM_BRANCH } else { 'main' }
$KitDir    = if ($env:DFIR_VM_DIR)    { $env:DFIR_VM_DIR }    else { Join-Path $env:USERPROFILE 'dfir-lab-vm' }
$SkipBuild = [bool]$env:DFIR_SKIP_BUILD
$MinFreeGB = 60   # ISO ~6 GB + thin VM that grows toward its 80 GB cap during install/provisioning

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [ok] $m"   -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!]  $m"   -ForegroundColor Yellow }
function Die($m)        { Write-Host "`n[X] $m`n"    -ForegroundColor Red; throw $m }
function Write-Fixed($m){ Write-Host "    [fixed] $m" -ForegroundColor Green }
function Write-Act($m)  { Write-Host "    [ACTION NEEDED] $m" -ForegroundColor Red }

# ===========================================================================
# Self-healing PREFLIGHT - runs FIRST, before any download or build.
# Detects environment problems, AUTO-FIXES the safe/reversible ones, and prints
# PASS / FIXED / ACTION-NEEDED for each in plain English. It collects every
# blocking problem and throws ONE consolidated summary at the end - so you see
# all problems at once instead of one-at-a-time.
#
# SAFETY: it never silently turns off a security feature. Things like Hyper-V,
# memory integrity, or Credential Guard are only REPORTED with the exact,
# reversible command to change them - you decide. (On a managed/DoD machine
# those are policy-controlled and we must not touch them behind your back.)
#
# Exports for the rest of the script: $script:vmwareRoot, $script:vmrun,
# $script:vmwareVer, and prepends VMware to $env:PATH.
# ===========================================================================
function Invoke-Preflight {
    Write-Step 'Preflight - checking your machine and auto-fixing what I safely can'
    $blocking = New-Object System.Collections.Generic.List[string]

    # --- 8a. TLS 1.2 (PowerShell 5.1 defaults can break HTTPS downloads) ----
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Write-Fixed 'Enabled TLS 1.2 for secure downloads (some 5.1 setups need this).'
    } catch { Write-Warn2 "Could not set TLS 1.2: $($_.Exception.Message)" }

    # --- 8b. Execution policy for THIS process only (reversible, scoped) ----
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force -ErrorAction Stop
        Write-Fixed 'Allowed script execution for this window only (Process scope - nothing permanent).'
    } catch { Write-Warn2 "Could not set process execution policy: $($_.Exception.Message)" }

    # --- 1. PowerShell version ---------------------------------------------
    $psv = $PSVersionTable.PSVersion
    if ($psv.Major -lt 5 -or ($psv.Major -eq 5 -and $psv.Minor -lt 1)) {
        Write-Warn2 "PowerShell $psv is older than 5.1. This should still work, but 5.1+ is recommended (it ships with Windows 10/11)."
    } else {
        Write-Ok "PowerShell $psv (5.1+ - good)."
    }

    # --- 2a. 64-bit OS ------------------------------------------------------
    if (-not [Environment]::Is64BitOperatingSystem) {
        Write-Act 'This is a 32-bit Windows. The lab VM and tools are 64-bit only.'
        $blocking.Add('64-bit Windows is required (your OS is 32-bit). Use a 64-bit Windows host.')
    } else {
        Write-Ok '64-bit Windows.'
    }

    # --- 2b. Elevation (admin) ---------------------------------------------
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Act 'This window is NOT running as Administrator. Packer needs admin to drive VMware.'
        $blocking.Add('Re-open PowerShell as Administrator (right-click -> "Run as administrator"), then run the one-liner again.')
    } else {
        Write-Ok 'Running as Administrator.'
    }

    # --- 5. VMware Workstation Pro present + version ------------------------
    $script:vmwareRoot = $null
    foreach ($p in @("$env:ProgramFiles\VMware\VMware Workstation",
                     "${env:ProgramFiles(x86)}\VMware\VMware Workstation")) {
        if ($p -and (Test-Path (Join-Path $p 'vmware.exe'))) { $script:vmwareRoot = $p; break }
    }
    if (-not $script:vmwareRoot) {
        try {
            $rk = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation' -ErrorAction Stop
            if ($rk.InstallPath -and (Test-Path (Join-Path $rk.InstallPath 'vmware.exe'))) { $script:vmwareRoot = $rk.InstallPath }
        } catch {}
    }
    if (-not $script:vmwareRoot) {
        Write-Act 'VMware Workstation Pro was not found - this is the one thing you must install yourself.'
        $blocking.Add(@'
Install VMware Workstation Pro (the kit drives it to build the VM):
  https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion
then re-run the one-liner.
'@)
    } else {
        $script:vmrun = Join-Path $script:vmwareRoot 'vmrun.exe'
        if (-not (Test-Path $script:vmrun)) {
            Write-Act "Found VMware at '$script:vmwareRoot' but vmrun.exe is missing - that means VMware Player, not Workstation Pro."
            $blocking.Add('Install VMware Workstation Pro (not just the free Player runtime) - the build needs vmrun.exe.')
        } else {
            $script:vmwareVer = (Get-Item (Join-Path $script:vmwareRoot 'vmware.exe')).VersionInfo.ProductVersion
            $env:PATH = "$script:vmwareRoot;$env:PATH"   # so Packer's vmware-iso builder finds vmrun/vmware
            $verMajor = 0; [int]::TryParse(($script:vmwareVer -split '\.')[0], [ref]$verMajor) | Out-Null
            Write-Ok "VMware Workstation Pro v$script:vmwareVer at $script:vmwareRoot."
            if ($verMajor -ge 17) {
                Write-Ok 'Workstation 17+ detected (the kit pins the v1.0.11 vmware Packer plugin, which also works here).'
            } else {
                Write-Ok "Workstation $verMajor.x detected - the kit pins the v1.0.11 vmware Packer plugin specifically for this (v2.x of the plugin would need Workstation 17.6+)."
            }
        }
    }

    # --- 3. CPU virtualization (VT-x / AMD-V) ------------------------------
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $cpu  = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $vfw  = $cpu.VirtualizationFirmwareEnabled
        $slat = $cpu.SecondLevelAddressTranslationExtensions
        if ($cs.HypervisorPresent) {
            # A hypervisor already owns VT-x, so VT-x is definitely ON in firmware.
            Write-Ok 'CPU virtualization is ON (a hypervisor is already using it).'
        } elseif ($vfw -eq $false) {
            Write-Act 'CPU virtualization (Intel VT-x / AMD-V) appears DISABLED in firmware. VMware cannot power on a 64-bit VM without it.'
            $blocking.Add(@'
Turn on CPU virtualization in your BIOS/UEFI (this CANNOT be fixed from Windows):
  1. Restart and enter BIOS/UEFI setup (usually F2, F10, DEL, or Esc at boot).
  2. Find "Intel Virtualization Technology" / "Intel VT-x", or on AMD "SVM Mode".
  3. Set it to ENABLED, save, and exit.
On a managed/work laptop this may be locked - your IT admin can enable it.
'@)
        } else {
            Write-Ok ('CPU virtualization available' + $(if ($slat) { ' (with SLAT).' } else { '.' }))
        }
    } catch { Write-Warn2 "Could not read CPU virtualization state: $($_.Exception.Message)" }

    # --- 4. Hyper-V / VBS / Credential Guard / memory integrity (REPORT-ONLY)
    # VMware Workstation 16.2.5 CAN run alongside Hyper-V via the Windows
    # Hypervisor Platform path (slower, but it works). So this is informational,
    # NOT blocking. We only TELL you the reversible fix - we never apply it,
    # because on a managed/DoD machine these are security controls.
    try {
        $hyperOn = $false
        $cs2 = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs2 -and $cs2.HypervisorPresent) { $hyperOn = $true }
        $hvci = $false
        try {
            $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
            if ($dg.SecurityServicesRunning -contains 1) { Write-Warn2 'Credential Guard is RUNNING (a security feature).' }
            if ($dg.SecurityServicesRunning -contains 2) { $hvci = $true }
        } catch {}
        try {
            $mi = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction Stop
            if ($mi.Enabled -eq 1) { $hvci = $true }
        } catch {}
        if ($hyperOn -or $hvci) {
            Write-Warn2 'A Windows hypervisor is active on this HOST (Hyper-V / WSL2 / Virtual Machine Platform / memory integrity / Credential Guard).'
            Write-Warn2 'VMware Workstation 16.2.5 can usually run alongside it (a bit slower). If - and only if - the build fails to POWER ON the VM, you can turn the host hypervisor off:'
            Write-Warn2 '   bcdedit /set hypervisorlaunchtype off      (reversible: set it back with ... auto)'
            Write-Warn2 '   ...then turn OFF "Memory integrity" in Windows Security > Device security > Core isolation, and REBOOT.'
            Write-Warn2 'NOTE: those are security features. On a managed/DoD machine they are controlled by policy - ask IT. I will NOT change them for you.'
        } else {
            Write-Ok 'No conflicting host hypervisor detected.'
        }
    } catch { Write-Warn2 "Could not read hypervisor/security state: $($_.Exception.Message)" }

    # --- 6. Free disk on the target drive ----------------------------------
    try {
        $driveLetter = ([System.IO.Path]::GetPathRoot($KitDir)).TrimEnd('\')
        $freeGB = [math]::Round((Get-PSDrive ($driveLetter.TrimEnd(':')) -ErrorAction Stop).Free / 1GB, 1)
        if ($freeGB -lt $MinFreeGB) {
            Write-Act "Only $freeGB GB free on $driveLetter - the build needs about $MinFreeGB GB."
            $blocking.Add("Free up space on $driveLetter (need ~$MinFreeGB GB, have $freeGB GB), OR set `$env:DFIR_VM_DIR to a drive with more room, then re-run.")
        } else {
            Write-Ok "Free disk on $driveLetter`: $freeGB GB (need ~$MinFreeGB GB)."
        }
    } catch { Write-Warn2 "Could not check free disk: $($_.Exception.Message)" }

    # --- 7. Internet reachability (GitHub for the kit/deps, Microsoft for ISO)
    $ghOk = $false; $msOk = $false
    try { $null = Invoke-WebRequest 'https://github.com' -UseBasicParsing -TimeoutSec 15 -Method Head; $ghOk = $true } catch {}
    try { $null = Invoke-WebRequest 'https://www.microsoft.com' -UseBasicParsing -TimeoutSec 15 -Method Head; $msOk = $true } catch {}
    if ($ghOk) { Write-Ok 'GitHub reachable (kit + vendored tools).' }
    else {
        Write-Act 'Cannot reach github.com - the kit and its vendored tools live there.'
        $blocking.Add('This host cannot reach github.com. The build needs internet ONCE to fetch the kit and tools (the finished VM then runs fully offline). Connect to a network that allows GitHub and re-run.')
    }
    if ($msOk) { Write-Ok 'Microsoft reachable (for the auto-fetched Windows ISO).' }
    else {
        Write-Warn2 'Cannot reach microsoft.com - auto-fetching the Windows ISO will likely fail on this network.'
        Write-Warn2 'That is OK: set $env:DFIR_ISO_URL to a local Windows 10 x64 ISO from your media share (e.g. file:///C:/iso/Win10.iso) and the build will use that instead.'
    }

    # --- 8c. Long path support (reversible registry flag; admin only) ------
    if ($isAdmin) {
        try {
            $lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
            if ($lp -ne 1) {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord -ErrorAction Stop
                Write-Fixed 'Enabled Windows long-path support (helps deep build paths; reversible - set LongPathsEnabled back to 0).'
            } else {
                Write-Ok 'Long-path support already enabled.'
            }
        } catch { Write-Warn2 "Could not set long-path support: $($_.Exception.Message)" }
    }

    # --- Consolidated verdict ----------------------------------------------
    if ($blocking.Count -gt 0) {
        $n = $blocking.Count
        $msg = "Preflight found $n thing(s) to fix before the build can run:`n`n"
        for ($i = 0; $i -lt $n; $i++) { $msg += "  $($i + 1)) " + ($blocking[$i] -replace "`n", "`n     ") + "`n`n" }
        $msg += 'Fix the item(s) above and re-run the one-liner - it is safe to run again (idempotent).'
        Die $msg
    }
    Write-Ok 'Preflight passed - environment looks good.'
}

Write-Host @'
  ____  _____ ___ ____    _          _      __     ____  __
 |  _ \|  ___|_ _|  _ \  | |    __ _| |__   \ \   / /  \/  |
 | | | | |_   | || |_) | | |   / _` | '_ \   \ \ / /| |\/| |
 | |_| |  _|  | ||  _ <  | |__| (_| | |_) |   \ V / | |  | |
 |____/|_|   |___|_| \_\ |_____\__,_|_.__/     \_/  |_|  |_|
        zepedara DFIR Lab VM  -  Packer auto-builder
'@ -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# 0/1. Preflight - elevation, prerequisites, self-healing fixes (all at once)
# ---------------------------------------------------------------------------
Invoke-Preflight
$vmrun = $script:vmrun   # carried out of preflight for the final "open the VM" hint

# ---------------------------------------------------------------------------
# 2. Packer
# ---------------------------------------------------------------------------
Write-Step 'Ensuring HashiCorp Packer is installed'
function Test-Packer { try { return [bool](Get-Command packer -ErrorAction Stop) } catch { return $false } }
function Update-SessionPath {
    $m = [Environment]::GetEnvironmentVariable('PATH','Machine')
    $u = [Environment]::GetEnvironmentVariable('PATH','User')
    foreach ($p in ("$m;$u" -split ';')) { if ($p -and (($env:PATH -split ';') -notcontains $p)) { $env:PATH = "$env:PATH;$p" } }
}

if (-not (Test-Packer)) {
    # 1) VENDORED direct download (works on a locked-down net - no package mgr,
    #    no releases.hashicorp.com). This is the reliable, offline-friendly path.
    Write-Warn2 'Installing Packer from the vendored deps-v1 release...'
    try {
        $dst = Join-Path $env:ProgramData 'packer'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $zip = Join-Path $env:TEMP 'packer.zip'
        Invoke-WebRequest "$DepsBase/packer_1.11.2_windows_amd64.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dst -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        if (($env:PATH -split ';') -notcontains $dst) { $env:PATH = "$dst;$env:PATH" }
        $mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
        if ($mp -notlike "*$dst*") { [Environment]::SetEnvironmentVariable('PATH', "$mp;$dst", 'Machine') }
    } catch {
        Write-Warn2 "Vendored Packer download failed: $($_.Exception.Message). Trying package managers..."
    }
    # 2) winget (verify AFTER - winget prints "No package found" without throwing)
    if (-not (Test-Packer) -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Trying Packer via winget...'
        cmd /c "winget install --id HashiCorp.Packer -e --accept-source-agreements --accept-package-agreements --silent" 2>&1 | Out-Null
        Update-SessionPath
    }
    # 3) choco
    if (-not (Test-Packer) -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Trying Packer via choco...'
        cmd /c "choco install packer -y" 2>&1 | Out-Null
        Update-SessionPath
    }
    # 4) LAST-RESORT direct download from HashiCorp (only if vendored + pkg mgrs failed)
    if (-not (Test-Packer)) {
        Write-Warn2 'Installing Packer via direct download from HashiCorp (last resort)...'
        $pv  = '1.11.2'
        $url = "https://releases.hashicorp.com/packer/$pv/packer_${pv}_windows_amd64.zip"
        $dst = Join-Path $env:ProgramData 'packer'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $zip = Join-Path $env:TEMP 'packer.zip'
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dst -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        if (($env:PATH -split ';') -notcontains $dst) { $env:PATH = "$dst;$env:PATH" }
        $mp = [Environment]::GetEnvironmentVariable('PATH','Machine')
        if ($mp -notlike "*$dst*") { [Environment]::SetEnvironmentVariable('PATH', "$mp;$dst", 'Machine') }
    }
}
if (-not (Test-Packer)) { Die 'Packer install failed. Install it manually from https://developer.hashicorp.com/packer/install and re-run.' }
Write-Ok "Packer: $((packer version) -split [Environment]::NewLine | Select-Object -First 1)"

# ---------------------------------------------------------------------------
# 3. Download the kit
# ---------------------------------------------------------------------------
Write-Step "Fetching the kit into $KitDir"
$rawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$repoUrl = "https://github.com/$RepoOwner/$RepoName.git"

if (Test-Path (Join-Path $KitDir '.git')) {
    Write-Warn2 'Kit already cloned - updating (git pull)'
    cmd /c "git -C `"$KitDir`" pull --ff-only" 1>$null 2>$null
} elseif (Get-Command git -ErrorAction SilentlyContinue) {
    git clone --branch $Branch --depth 1 $repoUrl $KitDir
} else {
    # zip fallback (no git on host)
    Write-Warn2 'git not found - downloading kit zip'
    $zip = Join-Path $env:TEMP 'dfir-lab-vm.zip'
    Invoke-WebRequest "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
    $tmp = Join-Path $env:TEMP 'dfir-lab-vm-extract'
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
    New-Item -ItemType Directory -Force -Path $KitDir | Out-Null
    Copy-Item "$($inner.FullName)\*" $KitDir -Recurse -Force
    Remove-Item $zip,$tmp -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path (Join-Path $KitDir 'packer\dfir-win.pkr.hcl'))) { Die "Kit download looks incomplete - missing packer\dfir-win.pkr.hcl under $KitDir" }
Write-Ok 'Kit ready'

# ---------------------------------------------------------------------------
# 4. Resolve the Windows ISO  (turnkey: auto-fetch a fresh link FROM MICROSOFT)
# ---------------------------------------------------------------------------
#   LEGAL: we never host Windows. If you did NOT set $env:DFIR_ISO_URL we run the
#   vendored Fido helper (tools\Fido.ps1, from github.com/pbatard/Fido, committed
#   into this kit so the ONLY external fetch is the ISO itself - resilient on a
#   locked-down network). Fido queries Microsoft's official download API and
#   returns a fresh, time-limited download link straight from Microsoft. The ISO
#   then downloads FROM MICROSOFT during the Packer build. A retail multi-edition
#   Win10 x64 ISO is what we get; the unattended setup auto-selects "Windows 10
#   Pro" (generic key, lab use only, 30-day rearm).
Write-Step 'Resolving the Windows ISO download link'
$IsoUrl      = $null
$IsoChecksum = $null
if ($env:DFIR_ISO_URL) {
    # You supplied your own ISO - use it verbatim (e.g. a local file:/// from a
    # media share on an air-gapped / DoD network). We never override your choice.
    $IsoUrl      = $env:DFIR_ISO_URL
    $IsoChecksum = if ($env:DFIR_ISO_SHA256) { "sha256:$($env:DFIR_ISO_SHA256)" } else { 'none' }
    Write-Ok 'Using your DFIR_ISO_URL override'
    Write-Warn2 "  $IsoUrl"
    if ($IsoChecksum -eq 'none') { Write-Warn2 'No DFIR_ISO_SHA256 set - integrity check disabled for your ISO.' }
} else {
    $fido = Join-Path $KitDir 'tools\Fido.ps1'
    if (-not (Test-Path $fido)) { Die "Vendored Fido helper missing at $fido - the kit download looks incomplete; re-run the one-liner." }
    Write-Warn2 'No DFIR_ISO_URL set - asking Microsoft for a fresh Windows 10 Pro (22H2 / x64 / English) link via Fido...'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $fidoOut = & $fido -Win 10 -Rel Latest -Ed Pro -Lang English -Arch x64 -GetUrl 2>$null
        $IsoUrl  = $fidoOut | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1
    } catch {
        Write-Warn2 "Fido raised: $($_.Exception.Message)"
        $IsoUrl = $null
    }
    if (-not $IsoUrl -or $IsoUrl -notmatch '^https?://') {
        Die @'
Could not auto-fetch a Windows ISO link from Microsoft.
This is expected on a locked-down / DoD network that blocks Microsoft's download API.

FIX - point the build at a local Windows 10 x64 ISO from your media share:

    $env:DFIR_ISO_URL = 'file:///C:/path/to/Win10_22H2_English_x64.iso'
    # optional integrity check (recommended):
    $env:DFIR_ISO_SHA256 = '<sha256-of-that-iso>'

then re-run the one-liner. A retail multi-edition Windows 10 x64 ISO (the kind
Fido or the Microsoft Eval Center hands out) works as-is - the unattended setup
auto-selects the "Windows 10 Pro" edition.
'@
    }
    $IsoChecksum = 'none'   # Microsoft's link is time-limited and has no stable published SHA256
    Write-Ok 'Got a fresh Microsoft ISO link (downloads from Microsoft at build time)'
    Write-Warn2 "  $($IsoUrl.Substring(0,[Math]::Min(96,$IsoUrl.Length)))..."
}

# ---------------------------------------------------------------------------
# 5. Build
# ---------------------------------------------------------------------------
$packerDir = Join-Path $KitDir 'packer'
Push-Location $packerDir
try {
    Write-Step 'Installing the vmware Packer plugin (offline, from vendored deps-v1)'
    $pluginZip = Join-Path $env:TEMP 'packer-plugin-vmware.zip'
    $pluginDir = Join-Path $env:TEMP 'packer-plugin-vmware'
    $pluginOk  = $false
    try {
        Invoke-WebRequest "$DepsBase/packer-plugin-vmware_v1.0.11_x5.0_windows_amd64.zip" -OutFile $pluginZip -UseBasicParsing
        Remove-Item $pluginDir -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $pluginZip -DestinationPath $pluginDir -Force
        $pluginExe = Get-ChildItem $pluginDir -Recurse -Filter 'packer-plugin-vmware*.exe' | Select-Object -First 1
        if (-not $pluginExe) { throw 'plugin .exe not found inside the vendored zip' }
        # Offline install: registers the plugin for source github.com/hashicorp/vmware.
        & packer plugins install --path "$($pluginExe.FullName)" "github.com/hashicorp/vmware"
        if ($LASTEXITCODE -eq 0) {
            $pluginOk = $true
            Write-Ok 'vmware plugin v1.0.11 installed offline from deps-v1'
        } else {
            Write-Warn2 "packer plugins install returned exit $LASTEXITCODE - will try online packer init as a fallback."
        }
    } catch {
        Write-Warn2 "Offline vmware plugin install failed: $($_.Exception.Message). Falling back to online 'packer init'."
    } finally {
        Remove-Item $pluginZip -Force -ErrorAction SilentlyContinue
    }
    if (-not $pluginOk) {
        # Fallback ONLY if the vendored offline install did not succeed (needs internet).
        packer init .
        if ($LASTEXITCODE -ne 0) { Die 'Could not install the vmware plugin offline (deps-v1) OR online (packer init). Check the deps-v1 release / network and re-run.' }
    }

    Write-Step 'Validating the template'
    # iso_url/iso_checksum are always passed now (resolved in step 4 above:
    # either your DFIR_ISO_URL override or a fresh Microsoft link via Fido).
    $varArgs = @('-var', "iso_url=$IsoUrl", '-var', "iso_checksum=$IsoChecksum")
    & packer validate @varArgs .
    if ($LASTEXITCODE -ne 0) { Die 'packer validate failed - see messages above.' }
    Write-Ok 'Template valid'

    if ($SkipBuild) {
        Write-Warn2 'DFIR_SKIP_BUILD is set - stopping before the build as requested.'
        Write-Host "`nTo build later:`n  cd `"$packerDir`"; packer build $($varArgs -join ' ') ." -ForegroundColor Cyan
        return
    }

    Write-Step 'Building the VM (this takes ~30-60 min: ISO download, Windows install, lab provisioning)'
    Write-Warn2 'A VMware window will appear and drive the install hands-free. Do not touch it.'
    & packer build -on-error=cleanup @varArgs .
    if ($LASTEXITCODE -ne 0) { Die 'packer build failed - see messages above. Re-run the one-liner to resume; it is idempotent.' }

    $out = Get-ChildItem -Path (Join-Path $packerDir 'output-dfir-lab-vm') -Filter *.vmx -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-Host "`n=====================================================================" -ForegroundColor Green
    Write-Host " DFIR Lab VM build complete!" -ForegroundColor Green
    Write-Host "=====================================================================" -ForegroundColor Green
    if ($out) {
        Write-Host "`n  VM (.vmx):  $($out.FullName)" -ForegroundColor White
        Write-Host "`n  Open it:    In VMware Workstation Pro -> File -> Open -> select the .vmx -> Power On" -ForegroundColor White
        Write-Host "  Or:         & `"$vmrun`" start `"$($out.FullName)`"" -ForegroundColor White
    }
    Write-Host @"

  Inside the VM, the Desktop has 'DFIR-LAB-README.html' explaining everything.
  Login:      Analyst / dfir   (change it; this is a throwaway lab VM)
  Lab path:   C:\dfir\lab   (the dfir-training-lab walkthrough, modules 01-10)
  Native:     EZ Tools / Chainsaw / Hayabusa are on PATH
  Container:  in a terminal run  dfir-aio   (opens the Linux dfir-aio:v2 toolbox in WSL2)
"@ -ForegroundColor White
}
finally { Pop-Location }
