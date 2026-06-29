# =============================================================================
# 00 - Enable WSL2 + install the Ubuntu distro (headless).
# Runs inside the building VM. A windows-restart provisioner follows this.
# =============================================================================
$ErrorActionPreference = 'Stop'
Write-Host '[wsl] Enabling Windows Subsystem for Linux + Virtual Machine Platform...'

# Feature enable via DISM (no reboot here; Packer reboots after this script).
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# Install the WSL2 kernel update package (idempotent).
$kernelUrl = 'https://wslstorestorage.blob.core.windows.net/wslblob/wsl_update_x64.msi'
$msi = "$env:TEMP\wsl_update_x64.msi"
try {
    Write-Host '[wsl] Downloading WSL2 kernel update...'
    Invoke-WebRequest $kernelUrl -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
    Write-Host '[wsl] WSL2 kernel update installed.'
} catch {
    Write-Warning "[wsl] Kernel MSI step failed ($($_.Exception.Message)); 'wsl --update' after reboot will fix it."
}

# Mark that distro install should happen after reboot (done by 10-docker.ps1,
# which runs once WSL2 is fully live). We only set features + kernel here so the
# reboot cleanly brings WSL2 online.
Write-Host '[wsl] Features staged. Rebooting next (Packer windows-restart).'
exit 0
