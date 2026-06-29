# =============================================================================
# 10 - Bring WSL2 fully online, install Ubuntu headless, install Docker engine
#      INSIDE the Ubuntu distro (no Docker Desktop / no GUI login needed).
# Runs after the windows-restart, so WSL2 features are active.
# =============================================================================
$ErrorActionPreference = 'Stop'

function Invoke-WSL([string]$cmd) {
    # Run a bash command in the Ubuntu distro as root, fail on non-zero.
    wsl.exe -d Ubuntu -u root -- bash -lic $cmd
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed ($LASTEXITCODE): $cmd" }
}

Write-Host '[wsl] Setting WSL default version to 2 + updating...'
wsl.exe --set-default-version 2 2>$null
wsl.exe --update 2>$null

Write-Host '[wsl] Installing Ubuntu distro (headless, no first-run prompt)...'
# --no-launch avoids the interactive user-creation prompt. Available on modern wsl.
$installed = $false
try {
    wsl.exe --install -d Ubuntu --no-launch
    if ($LASTEXITCODE -eq 0) { $installed = $true }
} catch {}

if (-not $installed) {
    # Fallback: download the Ubuntu appx and register it manually.
    Write-Host '[wsl] --install unavailable; falling back to appx download...'
    $appx = "$env:TEMP\ubuntu.appx"
    Invoke-WebRequest 'https://aka.ms/wslubuntu2204' -OutFile $appx -UseBasicParsing
    Add-AppxPackage $appx
}

# Initialise the distro (registers the rootfs) without creating an interactive user.
Write-Host '[wsl] Initialising Ubuntu rootfs...'
wsl.exe -d Ubuntu -u root -- bash -lic "echo wsl-ready" 2>$null
Start-Sleep -Seconds 5
wsl.exe --set-version Ubuntu 2 2>$null

# Create the analyst user inside WSL (matches the Windows account name).
Write-Host '[wsl] Creating analyst user + setting as default...'
Invoke-WSL "id analyst >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo analyst"
Invoke-WSL "echo 'analyst:dfir' | chpasswd"
Invoke-WSL "echo 'analyst ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/analyst && chmod 440 /etc/sudoers.d/analyst"
# Set default user for the distro.
try { ubuntu.exe config --default-user analyst } catch { Write-Warning '[wsl] ubuntu.exe config not found; default user stays root (harmless).' }

Write-Host '[docker] Installing Docker engine inside Ubuntu...'
Invoke-WSL "export DEBIAN_FRONTEND=noninteractive; apt-get update -y"
Invoke-WSL "export DEBIAN_FRONTEND=noninteractive; apt-get install -y docker.io ca-certificates curl uidmap"
Invoke-WSL "usermod -aG docker analyst || true"

# Start dockerd now and on every WSL boot (WSL has no systemd by default on older
# images; we use a lightweight start hook in /etc/profile.d + a boot command).
Invoke-WSL "mkdir -p /var/log; (dockerd >/var/log/dockerd.log 2>&1 &) ; sleep 8; docker info >/dev/null 2>&1 && echo '[docker] daemon up' || echo '[docker] daemon will start on first use'"

# Ensure dockerd auto-starts: WSL2 'boot.command' (wsl.conf) on modern WSL.
Invoke-WSL @'
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true
command="service docker start || (dockerd >/var/log/dockerd.log 2>&1 &)"
[user]
default=analyst
EOF
'@

Write-Host '[docker] Done. Restarting the distro so wsl.conf/systemd take effect...'
wsl.exe --terminate Ubuntu 2>$null
Start-Sleep -Seconds 3
Invoke-WSL "sleep 8; docker version >/dev/null 2>&1 && echo '[docker] OK after restart' || echo '[docker] will be ready on first dfir-aio launch'"
exit 0
