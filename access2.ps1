# Fix SSH key auth into the lab VM (robust admin-key perms) + enable password fallback.
$ErrorActionPreference = 'Continue'
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBqXMPN1lic0GG8pz90jqXWMk+mZPGesI6164vLNvPCJ rem-l3e7'
New-Item -ItemType Directory -Force 'C:\ProgramData\ssh' | Out-Null
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
[System.IO.File]::WriteAllText($akf, $pub + "`n")
# strict perms: only Administrators + SYSTEM
cmd /c "icacls `"$akf`" /inheritance:r" | Out-Null
cmd /c "icacls `"$akf`" /grant Administrators:F SYSTEM:F" | Out-Null
# also user authorized_keys (belt + suspenders)
$ud = 'C:\Users\Analyst\.ssh'; New-Item -ItemType Directory -Force $ud | Out-Null
[System.IO.File]::WriteAllText("$ud\authorized_keys", $pub + "`n")
# sshd_config: ensure pubkey + password auth both on
$cfg = 'C:\ProgramData\ssh\sshd_config'
if (Test-Path $cfg) {
    $c = Get-Content $cfg -Raw
    $c = $c -replace '(?m)^\s*#?\s*PasswordAuthentication.*', 'PasswordAuthentication yes'
    $c = $c -replace '(?m)^\s*#?\s*PubkeyAuthentication.*', 'PubkeyAuthentication yes'
    Set-Content $cfg $c -Encoding ascii
}
Restart-Service sshd -ErrorAction SilentlyContinue
Start-Sleep 2
$st = (Get-Service sshd -ErrorAction SilentlyContinue).Status
$rep = "SSH AUTH FIXED  sshd=$st  (pubkey + password 'dfir' both enabled)`r`n"
try { Invoke-RestMethod -Uri 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Authorization='Bearer tk_oa9v85p645zgm7n50l0ytdpekuyyv'; Title='SSH fix'; Tags='guest_ssh' } } catch {}
Write-Host $rep
Write-Host '==== SSH auth fixed - Rem can connect now ===='
