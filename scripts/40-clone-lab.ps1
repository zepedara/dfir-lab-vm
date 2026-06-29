# =============================================================================
# 40 - Clone the dfir-training-lab walkthrough (+ its bundled data) to C:\dfir\lab
#      so the VM has the modules locally. Also mirror it inside WSL at ~/lab so
#      the dfir-aio container can mount module data with the documented command.
# =============================================================================
$ErrorActionPreference = 'Stop'

$LabWin = 'C:\dfir\lab'
New-Item -ItemType Directory -Force -Path 'C:\dfir' | Out-Null

# Ensure git is present on Windows (winget on Win10 eval may need a moment).
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[lab] Installing git for Windows...'
    try {
        winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements --silent
        $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
    } catch {
        # Fallback: portable git zip is overkill here; use WSL git to clone to a
        # Windows path instead.
        Write-Warning '[lab] winget git failed; will clone via WSL git.'
    }
}

$repo = 'https://github.com/zepedara/dfir-training-lab.git'

if (Get-Command git -ErrorAction SilentlyContinue) {
    if (Test-Path (Join-Path $LabWin '.git')) {
        git -C $LabWin pull --ff-only
    } else {
        git clone --depth 1 $repo $LabWin
    }
} else {
    # Clone using WSL git directly into the Windows path via /mnt/c.
    wsl.exe -d Ubuntu -u root -- bash -lic "apt-get install -y git >/dev/null 2>&1; rm -rf /mnt/c/dfir/lab && git clone --depth 1 $repo /mnt/c/dfir/lab"
}

# --------------------- AIR-GAP: bake in ALL module data ----------------------
# The lab README says data is bundled OR fetched by a per-module get-data.sh.
# We run every get-data.sh NOW (build time) so the EVTX/Prefetch/hive samples are
# resident on disk and NOTHING is fetched at runtime. Also pull git-lfs if used.
Write-Host '[lab] Baking in module data (running any get-data.sh, pulling LFS)...'
$bakeScript = @'
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get install -y git git-lfs curl wget unzip ca-certificates >/dev/null 2>&1 || true
cd /mnt/c/dfir/lab || exit 0
git lfs install >/dev/null 2>&1 || true
git lfs pull >/dev/null 2>&1 || true
found=0
# Run each module's data fetcher so samples land in its data/ folder.
for s in $(find . -iname "get-data.sh" | sort); do
  found=1
  d=$(dirname "$s")
  echo "[lab]   running $s"
  ( cd "$d" && chmod +x ./get-data.sh 2>/dev/null; bash ./get-data.sh ) || echo "[lab]   WARN: $s returned non-zero (continuing)"
done
[ "$found" = 0 ] && echo "[lab]   no get-data.sh found - data is bundled in-repo."
# Quick inventory so the build log proves data is present.
echo "[lab]   data inventory:"; find . -type d -name data -maxdepth 2 -print -exec sh -c 'echo "      $(find "$0" -type f | wc -l) files"' {} \; 2>/dev/null | head -40
'@
wsl.exe -d Ubuntu -u root -- bash -lic $bakeScript

# Mirror inside WSL home for easy container mounts (analyst user).
Write-Host '[lab] Mirroring lab into WSL ~/lab for container mounts...'
wsl.exe -d Ubuntu -u analyst -- bash -lic "rm -rf ~/lab && cp -r /mnt/c/dfir/lab ~/lab 2>/dev/null || git clone --depth 1 $repo ~/lab; ls ~/lab | head" 2>$null

if (Test-Path (Join-Path $LabWin 'README.md')) {
    Write-Host "[lab] dfir-training-lab cloned to $LabWin"
} else {
    Write-Warning "[lab] Lab clone may have failed - check network. Repo: $repo"
}
exit 0
