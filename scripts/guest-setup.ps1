# DFIR lab - native forensic-tool installer.
# Run INSIDE the Windows lab VM, in an elevated PowerShell, with internet.
# Installs the analysis toolset (no firewall/remote changes) and clones the lab.
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base  = 'https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/scripts'
$steps = '30-windows-tools','32-native-env','34-native-tools','36-shim','40-clone-lab'
foreach ($s in $steps) {
    Write-Host ("==== " + (Get-Date -Format o) + "  RUN " + $s + " ====")
    try {
        $sp = Join-Path $env:TEMP ($s + '.ps1')
        Invoke-WebRequest "$base/$s.ps1" -OutFile $sp -UseBasicParsing
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sp
        Write-Host ("==== DONE " + $s + " (exit " + $LASTEXITCODE + ") ====")
    } catch {
        Write-Host ("==== ERROR " + $s + ": " + $_.Exception.Message + " ====")
    }
}
Write-Host ("==== ALL STEPS COMPLETE " + (Get-Date -Format o) + " ====")
