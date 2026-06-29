#Requires -Version 5.1
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
    4. Kick off the Packer build of the VM.
    5. Print clear next steps - where the .vmx lands and how to open it.

  LEGAL: This kit never redistributes Windows. The Packer build downloads a FREE
  Microsoft "Windows 10 Enterprise EVALUATION" ISO directly from Microsoft (or a
  URL you supply). You accept Microsoft's evaluation licence at build time.

  Tunable via environment variables BEFORE you run the one-liner, e.g.:
      $env:DFIR_VM_BRANCH = 'main'      # kit branch to pull
      $env:DFIR_VM_DIR    = 'C:\dfir-lab-vm'   # where to clone the kit
      $env:DFIR_SKIP_BUILD = '1'        # set up everything but do NOT run packer
      $env:DFIR_ISO_URL    = '<eval iso url>'  # override the eval ISO URL
      $env:DFIR_ISO_SHA256 = '<sha256>'        # checksum for the above
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Config (env-overridable)
# ---------------------------------------------------------------------------
$RepoOwner = 'zepedara'
$RepoName  = 'dfir-lab-vm'
$Branch    = if ($env:DFIR_VM_BRANCH) { $env:DFIR_VM_BRANCH } else { 'main' }
$KitDir    = if ($env:DFIR_VM_DIR)    { $env:DFIR_VM_DIR }    else { Join-Path $env:USERPROFILE 'dfir-lab-vm' }
$SkipBuild = [bool]$env:DFIR_SKIP_BUILD
$MinFreeGB = 30

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [ok] $m"   -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!]  $m"   -ForegroundColor Yellow }
function Die($m)        { Write-Host "`n[X] $m`n"    -ForegroundColor Red; exit 1 }

Write-Host @'
  ____  _____ ___ ____    _          _      __     ____  __
 |  _ \|  ___|_ _|  _ \  | |    __ _| |__   \ \   / /  \/  |
 | | | | |_   | || |_) | | |   / _` | '_ \   \ \ / /| |\/| |
 | |_| |  _|  | ||  _ <  | |__| (_| | |_) |   \ V / | |  | |
 |____/|_|   |___|_| \_\ |_____\__,_|_.__/     \_/  |_|  |_|
        zepedara DFIR Lab VM  -  Packer auto-builder
'@ -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# 0. Elevation
# ---------------------------------------------------------------------------
Write-Step 'Checking elevation'
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Please run this in an ELEVATED PowerShell (Run as Administrator). Packer needs admin to drive VMware.'
}
Write-Ok 'Running elevated'

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
Write-Step 'Checking prerequisites'

# --- VMware Workstation Pro -------------------------------------------------
$vmwareRoot = $null
foreach ($p in @(
    "$env:ProgramFiles\VMware\VMware Workstation",
    "${env:ProgramFiles(x86)}\VMware\VMware Workstation")) {
    if ($p -and (Test-Path (Join-Path $p 'vmware.exe'))) { $vmwareRoot = $p; break }
}
if (-not $vmwareRoot) {
    # registry fallback
    try {
        $rk = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation' -ErrorAction Stop
        if ($rk.InstallPath -and (Test-Path (Join-Path $rk.InstallPath 'vmware.exe'))) { $vmwareRoot = $rk.InstallPath }
    } catch {}
}
if (-not $vmwareRoot) {
    Die @'
VMware Workstation Pro was not found.
This kit targets VMware Workstation Pro on Windows (the vmware-iso builder).
Install Workstation Pro (free for personal use) from:
  https://www.vmware.com/products/desktop-hypervisor/workstation-and-fusion
then re-run the one-liner.
'@
}
$vmrun = Join-Path $vmwareRoot 'vmrun.exe'
if (-not (Test-Path $vmrun)) { Die "Found VMware at '$vmwareRoot' but vmrun.exe is missing - is this Workstation Pro (not just the VMware Player runtime)?" }
$vmwareVer = (Get-Item (Join-Path $vmwareRoot 'vmware.exe')).VersionInfo.ProductVersion
Write-Ok "VMware Workstation Pro detected: $vmwareRoot (v$vmwareVer)"
$env:PATH = "$vmwareRoot;$env:PATH"   # so packer's vmware-iso builder finds vmrun/vmware

# --- Hardware virtualization ------------------------------------------------
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    $vfw = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
    if ($cs.HypervisorPresent) {
        Write-Warn2 'A hypervisor (Hyper-V / WSL2 / Credential Guard) is present on the HOST.'
        Write-Warn2 'VMware Workstation can run alongside it on recent builds, but if the build'
        Write-Warn2 'fails to power on the VM, disable Hyper-V on the HOST (this VM ships its own WSL2 inside).'
    } elseif ($vfw -eq $false) {
        Write-Warn2 'CPU virtualization appears DISABLED in firmware. Enable Intel VT-x / AMD-V in BIOS/UEFI if the build cannot power on the VM.'
    } else {
        Write-Ok 'Hardware virtualization available'
    }
} catch { Write-Warn2 "Could not query virtualization state: $($_.Exception.Message)" }

# --- Free disk --------------------------------------------------------------
$drive = (Get-Item $KitDir -ErrorAction SilentlyContinue) ?? (Get-Item $env:USERPROFILE)
$driveLetter = ([System.IO.Path]::GetPathRoot($KitDir)).TrimEnd('\')
$freeGB = [math]::Round((Get-PSDrive ($driveLetter.TrimEnd(':'))).Free / 1GB, 1)
if ($freeGB -lt $MinFreeGB) {
    Die "Only $freeGB GB free on $driveLetter - the build needs ~$MinFreeGB GB (ISO ~5 GB + VM ~25 GB). Free up space or set `$env:DFIR_VM_DIR to a roomier drive."
}
Write-Ok "Free disk on $driveLetter`: $freeGB GB"

# --- Internet ---------------------------------------------------------------
try {
    $null = Invoke-WebRequest 'https://github.com' -UseBasicParsing -TimeoutSec 15 -Method Head
    Write-Ok 'Internet reachable'
} catch { Die 'No internet connectivity - the build needs to download the eval ISO and tools.' }

# ---------------------------------------------------------------------------
# 2. Packer
# ---------------------------------------------------------------------------
Write-Step 'Ensuring HashiCorp Packer is installed'
function Test-Packer { try { return [bool](Get-Command packer -ErrorAction Stop) } catch { return $false } }

if (-not (Test-Packer)) {
    $installed = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Warn2 'Installing Packer via winget...'
        try { winget install --id HashiCorp.Packer -e --accept-source-agreements --accept-package-agreements --silent; $installed = $true } catch {}
    }
    if (-not $installed -and (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Warn2 'Installing Packer via choco...'
        try { choco install packer -y; $installed = $true } catch {}
    }
    if (-not $installed) {
        # Direct zip fallback - no package manager required.
        Write-Warn2 'Installing Packer via direct download...'
        $pv  = '1.11.2'
        $url = "https://releases.hashicorp.com/packer/$pv/packer_${pv}_windows_amd64.zip"
        $dst = Join-Path $env:ProgramData 'packer'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $zip = Join-Path $env:TEMP 'packer.zip'
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $dst -Force
        Remove-Item $zip -Force
        $env:PATH = "$dst;$env:PATH"
        [Environment]::SetEnvironmentVariable('PATH', "$dst;$([Environment]::GetEnvironmentVariable('PATH','Machine'))", 'Machine')
    }
    # refresh PATH for winget/choco installs in this session
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
}
if (-not (Test-Packer)) { Die 'Packer is still not on PATH. Open a NEW elevated PowerShell and re-run, or install Packer manually: https://developer.hashicorp.com/packer/install' }
Write-Ok "Packer: $((packer version) -split "`n" | Select-Object -First 1)"

# ---------------------------------------------------------------------------
# 3. Download the kit
# ---------------------------------------------------------------------------
Write-Step "Fetching the kit into $KitDir"
$rawBase = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch"
$repoUrl = "https://github.com/$RepoOwner/$RepoName.git"

if (Test-Path (Join-Path $KitDir '.git')) {
    Write-Warn2 'Kit already cloned - updating (git pull)'
    git -C $KitDir pull --ff-only 2>$null
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
# 4. Build
# ---------------------------------------------------------------------------
$packerDir = Join-Path $KitDir 'packer'
Push-Location $packerDir
try {
    Write-Step 'Initialising Packer plugins (vmware)'
    packer init . 2>&1 | ForEach-Object { Write-Host "    $_" }

    Write-Step 'Validating the template'
    $varArgs = @()
    if ($env:DFIR_ISO_URL)    { $varArgs += @('-var', "iso_url=$($env:DFIR_ISO_URL)") }
    if ($env:DFIR_ISO_SHA256) { $varArgs += @('-var', "iso_checksum=sha256:$($env:DFIR_ISO_SHA256)") }
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
    & packer build -on-error=ask @varArgs .
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
