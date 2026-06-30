# DFIR lab one-shot setup. Run inside the lab VM (elevated, with internet):
#   iwr -useb https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/run.ps1 | iex
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$log = "$env:USERPROFILE\dfir-setup.log"
$T   = 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca'
$K   = 'tk_oa9v85p645zgm7n50l0ytdpekuyyv'
Remove-Item $log -ErrorAction SilentlyContinue
Write-Host '==== DFIR lab setup starting (this takes ~30-45 min) ===='
try {
    & { iwr -useb https://raw.githubusercontent.com/zepedara/dfir-lab-vm/main/scripts/guest-setup.ps1 | iex } *>&1 | Tee-Object -FilePath $log
} catch {
    ("WRAPPER: " + ($_ | Out-String)) | Tee-Object -FilePath $log -Append
}
finally {
    try {
        Invoke-RestMethod -Uri $T -Method Put -InFile $log -Headers @{ Authorization = "Bearer $K"; Filename = 'dfir-setup.log'; Title = 'DFIR VM setup log'; Tags = 'dfir_setup' }
        Write-Host '==== log sent to Rem ===='
    } catch { Write-Host ("log post failed: " + $_.Exception.Message) }
}
